#!/usr/bin/env bash
# scripts/delegate.sh — tool-agnostic delegation launcher, monitor, and helpers
#
# Subcommands:
#   delegate.sh <runtime> <task-id> [timeout-secs] [--continue] [--model ID]
#                                                    Launch (or resume) a task
#   delegate.sh status <task-id>                     Machine-readable status
#   delegate.sh stop <task-id>                       Terminate the task's agent tree safely
#   delegate.sh verify <task-id>                     Run the handoff's verification block
#   delegate.sh reconcile                           Report stale in_progress TODO.md entries
#   delegate.sh next-id                              Atomically allocate + reserve the next TASK-N
#   delegate.sh cleanup <task-id> [--force]          Remove a finished task's worktree + branch
#   delegate.sh version                              Print the launcher version
#
# ── Launch ───────────────────────────────────────────────────────────────────
# Handles the mechanical parts of delegation:
#   1. Validates the handoff document exists
#   2. Creates (or reuses) a verified git worktree. Refuses to launch if
#      isolation fails unless DELEGATE_ALLOW_UNISOLATED=1 was explicitly set.
#      A worktree separates code edits; it is not an OS security sandbox.
#   3. Launches the agent inside a self-contained supervisor process that:
#        - is the agent's real parent, so it can capture the agent's TRUE
#          exit code via `wait` — not just "the process is gone"
#        - races a timeout timer against natural completion and auto-cancels
#          the timer the instant the agent exits (removes the "must remember
#          to cancel the watchdog on success" footgun entirely)
#        - is itself launched with nohup, so it survives the calling
#          terminal/session closing
#   4. Records a best-effort PID fingerprint and (when verified safe) a
#      process-group id, so a later kill can never land on an unrelated
#      process that happens to reuse the PID, and can terminate a whole
#      process tree instead of a single PID
#
# Usage:
#   bash delegate.sh <runtime> <task-id> [timeout-seconds] [--continue] [--model ID]
#
# Arguments:
#   runtime         — opencode | pi | mimo | hermes | kimi | codex | agy
#   task-id         — TASK-N (e.g. TASK-1, TASK-3)
#   timeout-seconds — seconds before the watchdog kills the agent (default: 1800)
#   --continue      — resume the runtime's previous session in the same worktree
#                     (self-healing retry) instead of starting a fresh one
#   --model ID      — pass an explicit model to the runtime (only when the user
#                     asked for one; otherwise the runtime's configured default)
#
# Run it from the project root. The handoff document must already exist at:
#   .delegate/tasks/<task-id>.md
#
# Output (printed to stdout, one per line):
#   PID=<agent process ID>
#   LOG=<absolute path to log file>
#   WORK_DIR=<absolute path to worktree>
#
# Exit codes:
#   0 = agent launched successfully
#   1 = runtime not found, handoff missing, unsupported runtime, invalid
#       input, isolation failure, or the task's agent is still running
#
# ── Files written under .delegate/tasks/ ────────────────────────────────────
#   TASK-N.pid              real agent process id — signal/inspect this one
#   TASK-N.log               agent's combined stdout/stderr (previous attempt's
#                            log is rotated to TASK-N.log.prev on relaunch)
#   TASK-N.retries           self-healing retry counter (created as 0 on first
#                            launch, never reset by a relaunch; the caller
#                            increments it)
#   TASK-N.reserved          marker written by `next-id` so concurrent callers
#                            never receive the same id
#   TASK-N.timedout          written by the supervisor when the timeout fired
#   TASK-N.stopped           written by `stop` (deliberate termination)
#   TASK-N.watchdog.pid      supervisor process id (informational — to end a
#                            task early use `delegate.sh stop`; killing the
#                            supervisor leaves the agent and its timer running
#                            and no exit code is ever recorded)
#   TASK-N.exitcode          agent's real exit code, written once it exits
#   TASK-N.fingerprint       best-effort process identity (guards PID reuse)
#   TASK-N.pgid              process-group id, only written when verified safe
#   TASK-N.supervisor.sh     the generated supervisor script (kept for inspection)
#   TASK-N.log.size          last-seen log size, used by `status` for stall detection
#   TASK-N.lastpoll          mtime marker, used by `status` as a second stall signal
#   TASK-N.verify.log        output of the last `verify` run

set -euo pipefail

# Keep in step with every skill's metadata.version (a structure test enforces
# it). The workflow compares this with a project-pinned copy's `version` so a
# stale pinned launcher never overrides the bundled one.
DELEGATE_VERSION="1.4.0"

PROJECT_ROOT="$(pwd -P)"

# ── Shared helpers ───────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage:
  delegate.sh <runtime> <task-id> [timeout-secs] [--continue] [--model ID]
                                                   Launch (or resume) a task
  delegate.sh status <task-id>                     Print machine-readable status
  delegate.sh stop <task-id>                       Terminate the task's agent process tree
  delegate.sh verify <task-id>                     Run the handoff's verification block
  delegate.sh reconcile                            Report stale in_progress TODO.md entries
  delegate.sh next-id                              Allocate + reserve the next TASK-N (lock-protected)
  delegate.sh cleanup <task-id> [--force]          Remove the worktree + branch after you merged it
  delegate.sh version                              Print the launcher version
EOF
}

# Keep .delegate/ (task logs, PID files, nested worktrees) out of `git status`
# in the main tree without touching any tracked file: the repo-local exclude
# file is never committed. Without this, the first delegation leaves an
# untracked `.delegate/` behind and every later Step 0 sees a dirty tree.
ensure_delegate_ignored() {
  local exclude
  exclude=$(git -C "$PROJECT_ROOT" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$exclude" ] || return 0
  case "$exclude" in /*|[A-Za-z]:/*) ;; *) exclude="$PROJECT_ROOT/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  grep -qxF '.delegate/' "$exclude" 2>/dev/null && return 0
  printf '\n# delegate-skills runtime artifacts\n.delegate/\n' >> "$exclude" 2>/dev/null || true
}

# Strict identifiers keep all state files and branch names beneath .delegate.
validate_task_id() {
  [[ "$1" =~ ^TASK-[1-9][0-9]*$ ]] || {
    echo "ERROR: task-id must be TASK-N with a positive decimal N." >&2
    return 1
  }
}

validate_delegate_paths() {
  local task_id="${1:-}" path
  for path in "$PROJECT_ROOT/.delegate" "$PROJECT_ROOT/.delegate/tasks" "$PROJECT_ROOT/.delegate/worktrees"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
      echo "ERROR: delegation directories must be real directories: $path" >&2
      return 1
    fi
    if [ -d "$path" ] && [ "$(cd "$path" && pwd -P)" != "$path" ]; then
      echo "ERROR: delegation directory resolves outside its expected path: $path" >&2
      return 1
    fi
  done
  [ -z "$task_id" ] && return 0
  for path in "$PROJECT_ROOT/.delegate/tasks/$task_id".*; do
    if [ -L "$path" ] || [ -d "$path" ]; then
      echo "ERROR: task files must not be symlinks or directories: $path" >&2
      return 1
    fi
  done
  path="$PROJECT_ROOT/.delegate/worktrees/$task_id"
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
    echo "ERROR: worktree path must be a real directory: $path" >&2
    return 1
  fi
  if [ -d "$path" ] && [ "$(cd "$path" && pwd -P)" != "$path" ]; then
    echo "ERROR: worktree resolves outside its expected path: $path" >&2
    return 1
  fi
}

git_common_dir() {
  local directory="$1" common
  common=$(git -C "$directory" rev-parse --git-common-dir) || return 1
  case "$common" in /*|[A-Za-z]:/*) ;; *) common="$directory/$common" ;; esac
  (cd "$common" && pwd -P)
}

validate_worktree() {
  local directory="$1" branch="$2" top
  top=$(git -C "$directory" rev-parse --show-toplevel) || return 1
  [ "$(cd "$top" && pwd -P)" = "$directory" ] &&
    [ "$(git_common_dir "$directory")" = "$(git_common_dir "$PROJECT_ROOT")" ] &&
    [ "$(git -C "$directory" symbolic-ref --short HEAD)" = "$branch" ] || {
      echo "ERROR: existing worktree must belong to this repository and branch $branch." >&2
      return 1
    }
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

# Modification time of $1 as epoch seconds, portably: GNU `stat -c`, then
# BSD/macOS `stat -f`, then GNU `date -r`. (BSD `date -r` means "format these
# epoch SECONDS", so it must never be the first choice — relying on it alone
# silently disabled the stale-lock check on macOS.)
_mtime_epoch() {
  local out
  for out in "$(stat -c %Y "$1" 2>/dev/null)" "$(stat -f %m "$1" 2>/dev/null)" "$(date -r "$1" +%s 2>/dev/null)"; do
    [[ "$out" =~ ^[0-9]+$ ]] && { printf '%s' "$out"; return 0; }
  done
  return 1
}

# ── ps portability layer ──────────────────────────────────────────────────
# `ps -o <field>=` (custom output format) is the POSIX-ish way to pull a
# single field, but Cygwin/MSYS ps (the one Git Bash on Windows ships) does
# not support `-o` at all — it only offers a handful of fixed-column
# formats (-f, -l). Rather than let the fingerprint/pgid/child-scan features
# silently go dead on that platform, fall back to parsing a fixed-format
# `ps` by READING ITS OWN HEADER LINE and mapping column names to indices,
# so it isn't tied to one exact column order.
#   $1 = ps args string (word-split; caller-controlled, not user input)
#   $2 = field name to extract (PID, PPID, PGID, COMMAND, ...)
# COMMAND is special-cased to mean "from that column to end of line", since
# it's the only field that can itself contain spaces.
_ps_fixed_field() {
  local args="$1" field="$2"
  # shellcheck disable=SC2086
  ps $args 2>/dev/null | awk -v want="$field" '
    NR==1 { for (i=1;i<=NF;i++) if (toupper($i)==want) col=i; next }
    col {
      if (want=="COMMAND") { s=""; for (i=col;i<=NF;i++) s = s (i>col?" ":"") $i; print s }
      else print $col
    }'
}

# Every descendant of $1 (children, grandchildren, ...), deepest first, one
# PID per line. The launched PID is often not the engine — an npm shim that
# does not exec, a CLI that spawns its worker, the agent's own shells and test
# runners — and without a process group (no setsid on Git Bash or stock
# macOS) only a recursive walk reaches them. Uses `ps -eo pid=,ppid=` where
# supported, else the fixed-column MSYS fallback (header-mapped, like
# _ps_fixed_field). Best-effort: an empty result means "no children found".
_descendants() {
  local root="$1" table
  table=$(ps -eo pid=,ppid= 2>/dev/null) || table=""
  if [ -z "$table" ]; then
    table=$(ps -ef 2>/dev/null | awk '
      NR==1 { for (i=1;i<=NF;i++) { if (toupper($i)=="PID") p=i; if (toupper($i)=="PPID") pp=i }; next }
      p && pp { print $p, $pp }')
  fi
  [ -n "$table" ] || return 0
  printf '%s\n' "$table" | awk -v root="$root" '
    NF >= 2 { kids[$2] = kids[$2] " " $1 }
    END {
      n = 0; head = 0; tail = 1; queue[0] = root; seen[root] = 1
      while (head < tail) {
        m = split(kids[queue[head++]], c, " ")
        for (i = 1; i <= m; i++)
          if (c[i] != "" && !(c[i] in seen)) { seen[c[i]] = 1; queue[tail++] = c[i]; out[n++] = c[i] }
      }
      for (i = n - 1; i >= 0; i--) print out[i]
    }'
}

# Signal $2 (default TERM) to every descendant of $1, deepest first. Returns 0
# even when nothing was found or signalled.
_signal_descendants() {
  local pid="$1" sig="${2:-TERM}" victims child
  victims=$(_descendants "$pid") || victims=""
  [ -n "$victims" ] || return 0
  printf '%s\n' "$victims" | while read -r child; do
    [ -n "$child" ] && kill "-$sig" "$child" 2>/dev/null || true
  done
  return 0
}

# Best-effort process identity check — never blocks core functionality if the
# platform's `ps` doesn't support the fields used; falls back progressively.
pid_fingerprint() {
  local pid="$1" out
  out=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ') || out=""
  if [ -z "$out" ]; then
    out=$(ps -o comm= -p "$pid" 2>/dev/null | tr -s ' ') || out=""
  fi
  if [ -z "$out" ]; then
    out=$(_ps_fixed_field "-f -p $pid" COMMAND)
  fi
  printf '%s' "$out"
}

# True only when the task's recorded agent is still running: the PID is live,
# the supervisor has not recorded an exit code for it, and (when a fingerprint
# was recorded) the live process still matches it. A recycled PID that now
# belongs to some unrelated process must never read as "agent still running".
task_agent_alive() {
  local task_id="$1" pid="$2" tasks_dir="$PROJECT_ROOT/.delegate/tasks"
  [ -n "$pid" ] && pid_alive "$pid" || return 1
  [ -f "$tasks_dir/$task_id.exitcode" ] && return 1
  if [ -s "$tasks_dir/$task_id.fingerprint" ]; then
    local stored current
    stored=$(cat "$tasks_dir/$task_id.fingerprint" 2>/dev/null) || stored=""
    current=$(pid_fingerprint "$pid")
    [ -n "$current" ] && [ -n "$stored" ] && [ "$current" != "$stored" ] && return 1
  fi
  return 0
}

# Terminate a task's process tree, never the wrong one.
#   $1 = task-id   $2 = signal (TERM|KILL, default TERM)
kill_tree() {
  local task_id="$1" sig="${2:-TERM}"
  local tasks_dir="$PROJECT_ROOT/.delegate/tasks"
  local pid_file="$tasks_dir/$task_id.pid"
  local pgid_file="$tasks_dir/$task_id.pgid"
  local fp_file="$tasks_dir/$task_id.fingerprint"

  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file" 2>/dev/null) || pid=""
  [ -n "$pid" ] || return 0
  pid_alive "$pid" || return 0

  # PID-reuse guard: if the live process no longer matches the fingerprint
  # recorded at launch, it isn't our agent anymore — leave it alone.
  if [ -f "$fp_file" ]; then
    local stored current
    stored=$(cat "$fp_file" 2>/dev/null) || stored=""
    if [ -n "$stored" ]; then
      current=$(pid_fingerprint "$pid")
      if [ -n "$current" ] && [ "$current" != "$stored" ]; then
        echo "WARN: $task_id pid $pid no longer matches recorded fingerprint — skipping kill (likely PID reuse)" >&2
        return 0
      fi
    fi
  fi

  # Descendants first, deepest first (covers agents that spawn shells, test
  # runners or helper processes — and wrappers whose child is the real agent).
  _signal_descendants "$pid" "$sig"

  # Whole process group, but ONLY if launch verified this pid is its own
  # group leader — `kill -SIG -PID` otherwise risks hitting an unrelated,
  # live process group that happens to share this numeric id.
  if [ -f "$pgid_file" ] && [ "$(cat "$pgid_file" 2>/dev/null)" = "$pid" ]; then
    kill "-$sig" "-$pid" 2>/dev/null || true
  fi

  kill "-$sig" "$pid" 2>/dev/null || true
}

# ── Launch ───────────────────────────────────────────────────────────────────

cmd_launch() {
  local RUNTIME="${1:?Usage: delegate.sh <runtime> <task-id> [timeout-secs] [--continue] [--model ID]}"
  shift
  local TASK_ID="" TIMEOUT_SECS="" CONTINUE=0 MODEL="" MODEL_SET=0 HAVE_TIMEOUT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --continue) CONTINUE=1 ;;
      --model)
        [ $# -ge 2 ] || { echo "ERROR: --model requires a value." >&2; return 1; }
        MODEL="$2"; MODEL_SET=1; shift ;;
      --model=*) MODEL="${1#--model=}"; MODEL_SET=1 ;;
      *)
        if [ -z "$TASK_ID" ]; then TASK_ID="$1"
        elif [ "$HAVE_TIMEOUT" = 0 ]; then TIMEOUT_SECS="$1"; HAVE_TIMEOUT=1
        else echo "ERROR: unexpected argument: $1" >&2; usage; return 1
        fi ;;
    esac
    shift
  done
  [ -n "$TASK_ID" ] || { usage; return 1; }
  [ "$HAVE_TIMEOUT" = 1 ] || TIMEOUT_SECS=1800

  local TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  local TASK_FILE="$TASKS_DIR/$TASK_ID.md"
  local WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID"
  local LOG_FILE="$TASKS_DIR/$TASK_ID.log"
  local PID_FILE="$TASKS_DIR/$TASK_ID.pid"
  local WATCHDOG_FILE="$TASKS_DIR/$TASK_ID.watchdog.pid"
  local EXITCODE_FILE="$TASKS_DIR/$TASK_ID.exitcode"
  local FP_FILE="$TASKS_DIR/$TASK_ID.fingerprint"
  local PGID_FILE="$TASKS_DIR/$TASK_ID.pgid"
  local SUP_FILE="$TASKS_DIR/$TASK_ID.supervisor.sh"
  local TIMEDOUT_FILE="$TASKS_DIR/$TASK_ID.timedout"

  validate_task_id "$TASK_ID"
  validate_delegate_paths "$TASK_ID"
  [[ "$TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: timeout-secs must be a positive decimal integer." >&2
    return 1
  }
  # Model ids look like "gpt-5", "anthropic/claude-sonnet-4", "sonnet:high".
  # Refuse anything that could be parsed as a flag or carry shell metacharacters.
  if [ "$MODEL_SET" = 1 ] && ! [[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]; then
    echo "ERROR: --model must be a plain model id (letters, digits, . _ : / @ + -)." >&2
    return 1
  fi
  local ALLOW_UNISOLATED="${DELEGATE_ALLOW_UNISOLATED:-0}"
  local ALLOW_UNSAFE="${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}"
  case "$ALLOW_UNISOLATED:$ALLOW_UNSAFE" in 0:0|0:1|1:0|1:1) ;; *)
    echo "ERROR: DELEGATE_ALLOW_UNISOLATED and DELEGATE_ALLOW_UNSAFE_FLAGS must be 0 or 1." >&2
    return 1 ;;
  esac

  # ── Preflight ──────────────────────────────────────────────────────────
  if [ ! -f "$TASK_FILE" ]; then
    cat >&2 <<EOF
ERROR: Handoff document not found: $TASK_FILE
Write the handoff document before calling delegate.sh.
See the skill's workflow.md, Step 3, for the required format.
EOF
    exit 1
  fi

  if ! command -v "$RUNTIME" &>/dev/null; then
    cat >&2 <<EOF
ERROR: Runtime '$RUNTIME' not found on PATH.
Install it and ensure it is accessible, then retry.
  opencode  ->  npm install -g opencode-ai
  pi        ->  npm install -g @earendil-works/pi-coding-agent
  mimo      ->  npm install -g @mimo-ai/cli
  codex     ->  npm install -g @openai/codex
  hermes    ->  see Hermes Agent documentation
  kimi      ->  see Kimi Code documentation
  agy       ->  see Agy documentation
EOF
    exit 1
  fi

  case "$RUNTIME" in opencode|pi|mimo|hermes|kimi|codex|agy) ;; *)
    echo "ERROR: Unsupported runtime '$RUNTIME'." >&2
    return 1 ;;
  esac
  mkdir -p "$TASKS_DIR"

  # Two agents in one worktree corrupt each other. Refuse to relaunch while the
  # previous attempt's agent is still running — stop it first (Step 5 Case 2).
  if [ -s "$PID_FILE" ]; then
    local OLD_PID
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null) || OLD_PID=""
    if task_agent_alive "$TASK_ID" "$OLD_PID"; then
      echo "ERROR: $TASK_ID agent (pid $OLD_PID) is still running — stop it before relaunching." >&2
      return 1
    fi
  fi

  # ── Worktree ───────────────────────────────────────────────────────────
  local ISOLATION_FAILURE="" BRANCH="${RUNTIME}/${TASK_ID}" IN_GIT=0
  if git rev-parse --git-dir &>/dev/null && git rev-parse HEAD &>/dev/null; then
    IN_GIT=1
    ensure_delegate_ignored
    if [ -d "$WORK_DIR" ]; then
      validate_worktree "$WORK_DIR" "$BRANCH" || return 1
    else
      # A worktree directory deleted by hand stays registered ("prunable" in
      # `git worktree list`) and blocks `git worktree add` at the same path
      # until pruned — without this a task could never be resumed after a
      # manual cleanup, and the error blamed isolation.
      git worktree prune 2>/dev/null || true
      local WT_ERR=""
      if WT_ERR=$(git worktree add "$WORK_DIR" -b "$BRANCH" 2>&1) || \
         WT_ERR=$(git worktree add "$WORK_DIR" "$BRANCH" 2>&1); then
        validate_delegate_paths "$TASK_ID"
        validate_worktree "$WORK_DIR" "$BRANCH" || return 1
      else
        WT_ERR="${WT_ERR##*$'\n'}"
        ISOLATION_FAILURE="worktree creation failed${WT_ERR:+: $WT_ERR}"
      fi
    fi
  else
    ISOLATION_FAILURE="not a git repo with a committed HEAD"
  fi
  if [ -n "$ISOLATION_FAILURE" ]; then
    if [ "$ALLOW_UNISOLATED" != 1 ]; then
      echo "ERROR: $ISOLATION_FAILURE — refusing to launch without worktree isolation." >&2
      echo "Set DELEGATE_ALLOW_UNISOLATED=1 only after explicitly accepting edits in the project root." >&2
      return 1
    fi
    WORK_DIR="$PROJECT_ROOT"
    echo "WARN: DELEGATE_ALLOW_UNISOLATED=1 — $ISOLATION_FAILURE; agent will edit the project root without code isolation." >&2
  fi
  if [ "$ALLOW_UNSAFE" = 1 ]; then
    echo "WARN: DELEGATE_ALLOW_UNSAFE_FLAGS=1 — runtime approvals/sandbox protections may be bypassed; a worktree is not an OS security boundary." >&2
  fi

  # setsid gives the agent its own session/process-group for free when
  # available; skipped gracefully otherwise (e.g. Git Bash on Windows, which
  # typically lacks it) — kill_tree still works via its child-scan fallback,
  # just without the process-group layer.
  local SETSID_ARGS=()
  command -v setsid &>/dev/null && SETSID_ARGS=(setsid)

  # ── Resolve the per-runtime command as a safely-quoted string ───────────
  # Built once here (fast, synchronous — help-flag detection must run before
  # backgrounding) then embedded into the supervisor script below via
  # `printf %q`, so paths/args containing spaces or special characters
  # survive being written to a file and re-parsed by a fresh bash process.
  local INNER_CMD=""   # the command line the supervisor executes and waits on
  # A foreground cd followed by a plain command & keeps $! on the real CLI.
  # Backgrounding `cd X && cmd &` would instead record a wrapper subshell.
  local CD_LINE=""

  # Prompts. A fresh run executes the handoff; a --continue run resumes the
  # runtime's previous session (all runtimes scope "previous session" to the
  # working directory or most recent run, and we always cd into the worktree).
  local RUN_MSG="Execute the task described in the attached handoff document. Follow all instructions in it exactly."
  local READ_MSG="Read $TASK_FILE and execute the task described in it. Follow all instructions exactly. All changes must stay in $WORK_DIR."
  if [ "$CONTINUE" = 1 ]; then
    RUN_MSG="Continue the task from where you left off. The original handoff document is attached — re-read it if you need full context."
    READ_MSG="Continue the task from where you left off. The original handoff is at $TASK_FILE — re-read it if you need full context. All changes must stay in $WORK_DIR."
  fi

  case "$RUNTIME" in

    opencode)
      local OPENCODE_HELP OPENCODE_AUTO=""
      OPENCODE_HELP=$(opencode run --help 2>&1) || true
      # Deprecated flag checked first so --auto wins when a version supports both.
      if [ "$ALLOW_UNSAFE" = 1 ]; then
        echo "$OPENCODE_HELP" | grep -q -- "--dangerously-skip-permissions" && OPENCODE_AUTO="--dangerously-skip-permissions"
        echo "$OPENCODE_HELP" | grep -q -- "--auto" && OPENCODE_AUTO="--auto"
      fi
      local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup opencode run "$RUN_MSG" --dir "$WORK_DIR")
      [ "$CONTINUE" = 1 ] && args+=(--continue)
      [ -n "$MODEL" ] && args+=(-m "$MODEL")
      [ -n "$OPENCODE_AUTO" ] && args+=("$OPENCODE_AUTO")
      # --file is an array option: keep it last so nothing after it is swallowed.
      args+=(--file "$TASK_FILE")
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    pi)
      local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup pi -p)
      # pi never prompts before running bash/edit/write, whatever flags are
      # passed — say so on every launch, like kimi >= 2 below (policy: warn and
      # launch; the worktree is the only code isolation).
      echo "WARN: pi has no per-tool approval prompts; its tools run unprompted and the worktree is the only code isolation." >&2
      [ "$CONTINUE" = 1 ] && args+=(--continue)
      [ -n "$MODEL" ] && args+=(--model "$MODEL")
      # --approve only trusts project-local pi resources for this run; pi has
      # no per-tool approval prompts at all (see delegate-to-pi/SKILL.md).
      # Help-detected: pi's project-trust handling has moved between releases
      # (1.5 persists decisions in trust.json), so never pass a flag the
      # installed version no longer accepts.
      if [ "$ALLOW_UNSAFE" = 1 ]; then
        local PI_HELP
        PI_HELP=$(pi --help 2>&1) || true
        if echo "$PI_HELP" | grep -q -- "--approve"; then
          args+=(--approve)
        else
          echo "WARN: installed pi has no --approve flag; launching without it." >&2
        fi
      fi
      args+=("@$TASK_FILE" "$RUN_MSG")
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    mimo)
      local MIMO_HELP MIMO_ARGS=() MIMO_HAS_FILE=""
      MIMO_HELP=$(mimo run --help 2>&1) || true
      echo "$MIMO_HELP" | grep -q -- "--dir"  && MIMO_ARGS+=(--dir "$WORK_DIR")
      [ "$CONTINUE" = 1 ] && echo "$MIMO_HELP" | grep -q -- "--continue" && MIMO_ARGS+=(--continue)
      [ -n "$MODEL" ] && MIMO_ARGS+=(-m "$MODEL")
      [ "$ALLOW_UNSAFE" = 1 ] && echo "$MIMO_HELP" | grep -q "dangerously-skip-permissions" && MIMO_ARGS+=(--dangerously-skip-permissions)
      # --file is an array option: keep it last.
      echo "$MIMO_HELP" | grep -q -- "--file" && { MIMO_HAS_FILE=1; MIMO_ARGS+=(--file "$TASK_FILE"); }
      if [ -n "$MIMO_HAS_FILE" ]; then
        local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup mimo run "$RUN_MSG" ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"})
      else
        local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup mimo run "$READ_MSG" ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"})
      fi
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    hermes)
      local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup hermes chat -q "$READ_MSG" -Q)
      [ "$CONTINUE" = 1 ] && args+=(--continue)
      [ -n "$MODEL" ] && args+=(-m "$MODEL")
      [ "$ALLOW_UNSAFE" = 1 ] && args+=(--yolo --accept-hooks)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    kimi)
      local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup kimi -p "$READ_MSG")
      # kimi's continue flag is lowercase -c ("continue the previous session
      # for the working directory"); -C does not exist.
      [ "$CONTINUE" = 1 ] && args+=(-c)
      [ -n "$MODEL" ] && args+=(-m "$MODEL")
      # kimi-code 2.x: `--prompt/-p` cannot be combined with --yolo, --auto or
      # --plan (startup is rejected), and print mode already runs in auto
      # permission mode — no approval is ever requested; only static deny
      # rules apply. Pre-2.0 builds still take -y as the explicit opt-in.
      local KIMI_VERSION KIMI_MAJOR
      KIMI_VERSION=$(kimi --version 2>/dev/null | head -1) || KIMI_VERSION=""
      KIMI_MAJOR=$(printf '%s' "$KIMI_VERSION" | grep -oE '[0-9]+' | head -1) || KIMI_MAJOR=""
      if [ "${KIMI_MAJOR:-0}" -ge 2 ] 2>/dev/null; then
        echo "WARN: kimi $KIMI_VERSION print mode (-p) never asks for approval (static deny rules still apply); the worktree is the only code isolation." >&2
        [ "$ALLOW_UNSAFE" = 1 ] && echo "WARN: kimi >= 2 rejects -y with -p; DELEGATE_ALLOW_UNSAFE_FLAGS adds nothing for kimi." >&2
      else
        [ "$ALLOW_UNSAFE" = 1 ] && args+=(-y)
      fi
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    codex)
      # codex is expressed as a pipeline: a framing printf + cat piped into
      # codex. Both stages are quoted independently and rejoined with a
      # literal `|` — the supervisor's `$!` after backgrounding this whole
      # line is codex's own PID (last command in the pipeline), which is
      # what makes an accurate `wait` possible below.
      local pre_q catq codexq codex_args INNER_CMD_STDIN
      if [ "$CONTINUE" = 1 ]; then
        # `codex exec resume` accepts neither -C/--cd nor -s/--sandbox: the
        # supervisor's cd puts it in the worktree (resume --last filters by
        # cwd), and the sandbox mode goes through a config override instead.
        pre_q=$(printf '%q ' printf '%s\n' "$RUN_MSG")
        INNER_CMD_STDIN="$pre_q"
        codex_args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup codex exec resume --last)
        if [ "$ALLOW_UNSAFE" = 1 ]; then
          codex_args+=(--dangerously-bypass-approvals-and-sandbox)
        else
          codex_args+=(-c 'sandbox_mode="workspace-write"')
        fi
      else
        pre_q=$(printf '%q ' printf '%s\n\n' "Execute the task described in the handoff document below. Follow all instructions in it exactly.")
        catq=$(printf '%q ' cat "$TASK_FILE")
        INNER_CMD_STDIN="{ $pre_q; $catq; }"
        codex_args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup codex exec -C "$WORK_DIR")
        if [ "$ALLOW_UNSAFE" = 1 ]; then
          codex_args+=(--dangerously-bypass-approvals-and-sandbox)
        else
          codex_args+=(-s workspace-write)
        fi
      fi
      [ -n "$MODEL" ] && codex_args+=(-m "$MODEL")
      # Codex refuses to run outside a git repository unless told otherwise;
      # only reachable here after an explicit DELEGATE_ALLOW_UNISOLATED=1.
      [ "$IN_GIT" = 0 ] && codex_args+=(--skip-git-repo-check)
      codex_args+=(-)
      codexq=$(printf '%q ' "${codex_args[@]}")
      INNER_CMD="$INNER_CMD_STDIN | $codexq"
      ;;

    agy)
      local args=(${SETSID_ARGS[@]+"${SETSID_ARGS[@]}"} nohup agy --print "$READ_MSG" --add-dir "$WORK_DIR")
      [ "$CONTINUE" = 1 ] && args+=(--continue)
      [ -n "$MODEL" ] && args+=(--model "$MODEL")
      [ "$ALLOW_UNSAFE" = 1 ] && args+=(--dangerously-skip-permissions)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    *)
      echo "ERROR: Unsupported runtime '$RUNTIME'." >&2
      echo "Supported: opencode pi mimo hermes kimi codex agy" >&2
      exit 1
      ;;

  esac

  CD_LINE="cd $(printf '%q' "$WORK_DIR") || exit 1
"

  # ── Reset per-attempt state from any previous attempt ───────────────────
  # A relaunch (self-healing retry) must not inherit the last attempt's exit
  # code, timeout marker, fingerprint, process group, stall-detection markers
  # or — critically — its PID file, which the wait loop below polls for. The
  # previous log is kept as TASK-N.log.prev for diagnosis. The retry counter
  # is deliberately NOT reset (see below).
  [ -f "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE.prev"
  rm -f "$PID_FILE" "$EXITCODE_FILE" "$FP_FILE" "$PGID_FILE" "$TIMEDOUT_FILE" "$TASKS_DIR/$TASK_ID.stopped" \
        "$TASKS_DIR/$TASK_ID.log.size" "$TASKS_DIR/$TASK_ID.lastpoll"

  # ── Write the supervisor script ──────────────────────────────────────────
  # The supervisor launches the real agent as ITS OWN child (so `wait` yields
  # a genuine exit code, not a guess), races a timeout timer against natural
  # completion, auto-cancels that timer the instant the agent exits, and
  # records a PID fingerprint + process-group id for safe later termination.
  cat > "$SUP_FILE" <<SUP
#!/usr/bin/env bash
set -uo pipefail
TIMEOUT_SECS=$(printf '%q' "$TIMEOUT_SECS")
PID_FILE=$(printf '%q' "$PID_FILE")
EXITCODE_FILE=$(printf '%q' "$EXITCODE_FILE")
FP_FILE=$(printf '%q' "$FP_FILE")
PGID_FILE=$(printf '%q' "$PGID_FILE")
TIMEDOUT_FILE=$(printf '%q' "$TIMEDOUT_FILE")

$CD_LINE$INNER_CMD &
RUNTIME_PID=\$!
echo "\$RUNTIME_PID" > "\$PID_FILE"

FP=\$(ps -o lstart= -p "\$RUNTIME_PID" 2>/dev/null | tr -s ' ') || FP=""
[ -z "\$FP" ] && { FP=\$(ps -o comm= -p "\$RUNTIME_PID" 2>/dev/null | tr -s ' ') || FP=""; }
[ -z "\$FP" ] && FP=\$(_ps_fixed_field "-f -p \$RUNTIME_PID" COMMAND)
[ -n "\$FP" ] && printf '%s' "\$FP" > "\$FP_FILE"

PGID=\$(ps -o pgid= -p "\$RUNTIME_PID" 2>/dev/null | tr -d ' ') || PGID=""
[ -z "\$PGID" ] && PGID=\$(_ps_fixed_field "-l -p \$RUNTIME_PID" PGID)
[ -n "\$PGID" ] && [ "\$PGID" = "\$RUNTIME_PID" ] && echo "\$PGID" > "\$PGID_FILE"

# Timer. Its sleeps run as waited-on children so cancelling the timer also
# reaps the sleep instead of orphaning it. On expiry it records the timeout
# and signals every descendant of the agent (deepest first — the engine
# behind a wrapper, the agent's shells and test runners), then the agent's
# whole process group when launch verified it leads one (setsid), then the
# agent itself.
signal_agent() {
  _signal_descendants "\$RUNTIME_PID" "\$1"
  if [ -s "\$PGID_FILE" ] && [ "\$(cat "\$PGID_FILE" 2>/dev/null)" = "\$RUNTIME_PID" ]; then
    kill "-\$1" "-\$RUNTIME_PID" 2>/dev/null
  fi
  kill "-\$1" "\$RUNTIME_PID" 2>/dev/null
}
(
  SLEEP_PID=""
  trap '[ -n "\$SLEEP_PID" ] && kill "\$SLEEP_PID" 2>/dev/null; exit 0' TERM
  sleep "\$TIMEOUT_SECS" & SLEEP_PID=\$!; wait "\$SLEEP_PID"
  echo "\$TIMEOUT_SECS" > "\$TIMEDOUT_FILE"
  signal_agent TERM
  sleep 30 & SLEEP_PID=\$!; wait "\$SLEEP_PID"
  signal_agent KILL
) &
TIMER_PID=\$!

EXIT_CODE=0
wait "\$RUNTIME_PID" || EXIT_CODE=\$?
echo "\$EXIT_CODE" > "\$EXITCODE_FILE"

# Auto-cancel the timer now that the agent has actually finished — this is
# the single biggest source of the "must remember to cancel the watchdog on
# success" footgun in earlier versions of this script.
kill "\$TIMER_PID" 2>/dev/null || true
SUP

  chmod +x "$SUP_FILE"

  # Exported so the supervisor (a separate bash process invoked below) can
  # call the same Cygwin/MSYS-safe ps helpers used elsewhere in this script,
  # without duplicating the awk logic in the generated file.
  export -f _ps_fixed_field _descendants _signal_descendants

  # ── Launch the supervisor, nohup'd so it survives the calling session ───
  nohup bash "$SUP_FILE" > "$LOG_FILE" 2>&1 &
  local SUPERVISOR_PID=$!
  echo "$SUPERVISOR_PID" > "$WATCHDOG_FILE"

  # Initialise the retry counter on the FIRST launch only. Self-healing
  # increments it before relaunching; resetting it here would let a task
  # retry forever (the caller's "RETRIES >= 2 → failed" check never trips).
  [ -f "$TASKS_DIR/$TASK_ID.retries" ] || echo 0 > "$TASKS_DIR/$TASK_ID.retries"

  # Wait for the supervisor to record the real agent PID before reporting —
  # callers read PID_FILE immediately after this script returns. If it never
  # appears, nothing can monitor this attempt: refusing (and tearing the
  # supervisor down) beats printing PID=unknown with exit 0, after which
  # `status` says NOT_FOUND and the workflow launches a second agent.
  local waited=0
  while [ ! -s "$PID_FILE" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -s "$PID_FILE" ]; then
    _signal_descendants "$SUPERVISOR_PID" KILL
    kill -KILL "$SUPERVISOR_PID" 2>/dev/null || true
    rm -f "$WATCHDOG_FILE"
    echo "ERROR: $TASK_ID supervisor did not record an agent PID within 10s — launch aborted (see $LOG_FILE)." >&2
    return 1
  fi

  # ── Report ────────────────────────────────────────────────────────────
  echo "PID=$(cat "$PID_FILE")"
  echo "LOG=$LOG_FILE"
  echo "WORK_DIR=$WORK_DIR"
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
  local TASK_ID="${1:?Usage: delegate.sh status <task-id>}"
  validate_task_id "$TASK_ID"
  validate_delegate_paths "$TASK_ID"
  local TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  local PID_FILE="$TASKS_DIR/$TASK_ID.pid"
  local LOG_FILE="$TASKS_DIR/$TASK_ID.log"
  local EXITCODE_FILE="$TASKS_DIR/$TASK_ID.exitcode"
  local RETRIES_FILE="$TASKS_DIR/$TASK_ID.retries"
  local SIZE_FILE="$TASKS_DIR/$TASK_ID.log.size"
  local WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID"
  [ -d "$WORK_DIR" ] || WORK_DIR="$PROJECT_ROOT"

  if [ ! -f "$PID_FILE" ]; then
    echo "STATE=NOT_FOUND"
    return 0
  fi

  local PID RETRIES=0
  PID=$(cat "$PID_FILE" 2>/dev/null) || PID=""
  if [ -f "$RETRIES_FILE" ]; then
    RETRIES=$(cat "$RETRIES_FILE" 2>/dev/null) || RETRIES=0
  fi

  local LOG_SIZE=0
  [ -f "$LOG_FILE" ] && { LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null) || LOG_SIZE=0; }
  local PREV_SIZE=-1
  [ -f "$SIZE_FILE" ] && { PREV_SIZE=$(cat "$SIZE_FILE" 2>/dev/null) || PREV_SIZE=-1; }
  echo "$LOG_SIZE" > "$SIZE_FILE"

  if task_agent_alive "$TASK_ID" "$PID"; then
    # Second liveness signal alongside log growth: any file in the worktree
    # touched more recently than our own last poll marker means the agent is
    # doing something even if it hasn't written to the log this cycle (e.g.
    # buffered stdout, or a long silent compile) — avoids killing a healthy
    # but quiet agent on log size alone.
    local MTIME_MARKER="$TASKS_DIR/$TASK_ID.lastpoll"
    local FS_ACTIVITY="unknown"
    if [ -d "$WORK_DIR" ]; then
      if [ -f "$MTIME_MARKER" ]; then
        # Prune .delegate (status's own bookkeeping files live there whenever
        # the project root is the work dir) and .git — neither is agent work,
        # and counting them made a silent agent look busy forever.
        if find "$WORK_DIR" \( -path "$WORK_DIR/.delegate" -o -path "$WORK_DIR/.git" \) -prune \
             -o -type f -newer "$MTIME_MARKER" -print 2>/dev/null | grep -q .; then
          FS_ACTIVITY="yes"
        else
          FS_ACTIVITY="no"
        fi
      fi
      touch "$MTIME_MARKER" 2>/dev/null || true
    fi

    if [ "$PREV_SIZE" != "-1" ] && [ "$LOG_SIZE" = "$PREV_SIZE" ] && [ "$FS_ACTIVITY" != "yes" ]; then
      echo "STATE=STALLED"
    else
      echo "STATE=RUNNING"
    fi
    echo "PID=$PID"
    echo "LOG_SIZE=$LOG_SIZE"
    echo "RETRIES=$RETRIES"
    return 0
  fi

  # Process is gone — classify. The timeout / stop markers come first and do
  # not depend on an exit code: if the supervisor itself died (session
  # teardown, a killed watchdog) no .exitcode is ever written, and a task that
  # was deliberately stopped must not read as a launch failure that Step 5
  # Case 1 would relaunch. Then the real exit code when we have one; a nonzero
  # exit with almost no output is a startup failure (bad flag, auth, missing
  # model) — workflow Step 5, Case 1.
  local CODE=""
  [ -f "$EXITCODE_FILE" ] && { CODE=$(cat "$EXITCODE_FILE" 2>/dev/null) || CODE=""; }
  if [ -f "$TASKS_DIR/$TASK_ID.timedout" ]; then
    echo "STATE=TIMED_OUT"
  elif [ -f "$TASKS_DIR/$TASK_ID.stopped" ]; then
    echo "STATE=STOPPED"
  elif [ -z "$CODE" ]; then
    if [ "$LOG_SIZE" -lt 500 ]; then echo "STATE=LAUNCH_FAILED"; else echo "STATE=EXITED_UNKNOWN"; fi
  elif [ "$CODE" = "0" ]; then
    echo "STATE=EXITED_OK"
  elif [ "$LOG_SIZE" -lt 500 ]; then
    echo "STATE=LAUNCH_FAILED"
  else
    echo "STATE=EXITED_FAILED"
  fi
  [ -n "$CODE" ] && echo "EXITCODE=$CODE"
  echo "PID=$PID"
  echo "LOG_SIZE=$LOG_SIZE"
  echo "RETRIES=$RETRIES"
}

# ── Verify ───────────────────────────────────────────────────────────────────

cmd_verify() {
  local TASK_ID="${1:?Usage: delegate.sh verify <task-id>}"
  validate_task_id "$TASK_ID"
  validate_delegate_paths "$TASK_ID"
  local TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  local TASK_FILE="$TASKS_DIR/$TASK_ID.md"
  local WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID"
  [ -d "$WORK_DIR" ] || WORK_DIR="$PROJECT_ROOT"

  if [ ! -f "$TASK_FILE" ]; then
    echo "ERROR: handoff not found: $TASK_FILE" >&2
    return 1
  fi

  # Extract the fenced ```bash (or ```sh) block(s) under "## Verification Expectations".
  local BLOCK
  BLOCK=$(awk '
    /^## Verification Expectations/ { infield=1; next }
    infield && !incode && /^## / { infield=0 }
    infield && !incode && /^```(bash|sh|shell)[[:space:]]*$/ { incode=1; next }
    infield && incode && /^```/ { incode=0; next }
    infield && incode { print }
  ' "$TASK_FILE")

  if [ -z "$BLOCK" ]; then
    echo "STATE=NO_VERIFICATION_BLOCK"
    echo "Add a \`\`\`bash fenced block under '## Verification Expectations' in $TASK_FILE to enable automated verification." >&2
    return 2
  fi

  local VERIFY_LOG="$TASKS_DIR/$TASK_ID.verify.log"
  local CODE=0
  # errexit + pipefail: every command in the block is a check. Without them a
  # multi-line block's status is only its LAST command's, so `npm test` could
  # fail and a trailing `test -f x` would still report PASS. stdin is closed so
  # an interactive command fails fast instead of hanging the review loop.
  ( cd "$WORK_DIR" && bash -eo pipefail -c "$BLOCK" ) < /dev/null > "$VERIFY_LOG" 2>&1 || CODE=$?

  if [ "$CODE" -eq 0 ]; then
    echo "STATE=PASS"
  else
    echo "STATE=FAIL"
    echo "EXITCODE=$CODE"
  fi
  echo "LOG=$VERIFY_LOG"
  return "$CODE"
}

# ── Reconcile ────────────────────────────────────────────────────────────────

cmd_reconcile() {
  validate_delegate_paths
  local TODO_FILE="$PROJECT_ROOT/TODO.md"
  if [ ! -f "$TODO_FILE" ]; then
    echo "No TODO.md found — nothing to reconcile."
    return 0
  fi

  local TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  local FOUND=0

  # Parse each "## [TASK-N]" block and its status: line, and — for
  # in_progress ones — check whether the process it names is actually alive.
  # Uses process substitution (not a pipe into `while read`) so FOUND updates
  # inside the loop are visible after it, rather than being lost in a subshell.
  while IFS='|' read -r header status; do
    [[ "$status" == *"in_progress"* ]] || continue
    local TASK_ID
    TASK_ID=$(echo "$header" | sed -E 's/^## \[(TASK-[0-9]+)\].*/\1/')
    local PID_FILE="$TASKS_DIR/$TASK_ID.pid"
    if [ ! -f "$PID_FILE" ]; then
      echo "STALE $TASK_ID reason=no_pid_file (never launched via delegate.sh, or its state files were cleaned up)"
      FOUND=1
      continue
    fi
    local PID
    PID=$(cat "$PID_FILE" 2>/dev/null) || PID=""
    if ! task_agent_alive "$TASK_ID" "$PID"; then
      echo "STALE $TASK_ID pid=$PID reason=process_not_running (likely an orphaned entry from a crashed or closed session — safe to mark 'stale' in TODO.md and resume with --continue)"
      FOUND=1
    fi
  done < <(awk '
    /^## \[TASK-[0-9]+\]/ { if (id != "") print id "|" status; id=$0; status="" }
    /^- status:/ { status=$0 }
    END { if (id != "") print id "|" status }
  ' "$TODO_FILE")

  [ "$FOUND" -eq 0 ] && echo "No stale in_progress tasks found."
  return 0
}

# ── Next task ID (lock-protected) ─────────────────────────────────────────────

cmd_next_id() {
  validate_delegate_paths
  local LOCK_DIR="$PROJECT_ROOT/.delegate/todo.lock"
  local STALE_AFTER=30   # seconds — a lock dir older than this is assumed
                         # orphaned by a crashed process, not a live holder.

  mkdir -p "$PROJECT_ROOT/.delegate"

  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -d "$LOCK_DIR" ]; then
      local mtime age
      mtime=$(_mtime_epoch "$LOCK_DIR") || mtime=""
      if [ -n "$mtime" ]; then
        age=$(( $(date +%s) - mtime ))
        if [ "$age" -gt "$STALE_AFTER" ]; then
          rmdir "$LOCK_DIR" 2>/dev/null || true
          continue
        fi
      fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
      echo "ERROR: could not acquire the TODO.md lock after 10s — a concurrent 'delegate.sh next-id' may be stuck. Remove $LOCK_DIR manually if no delegation is actually running." >&2
      return 1
    fi
    sleep 0.1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' RETURN

  # grep exits nonzero (2) when one of TODO.md/TODO-ARCHIVE.md is missing,
  # even if it matched in the other — with pipefail active that would trip
  # the pipeline's exit status and, if naively caught with `|| LAST_N=""`,
  # silently discard a real match. Neutralise grep's own exit status inside
  # the pipe instead, so only sed/sort/tail determine the outcome.
  #
  # The ledger alone is not enough: the caller appends its TODO.md block only
  # AFTER this returns, so a second caller taking the lock in that window would
  # read the same max and get the same id. Every id handed out is therefore
  # also reserved as .delegate/tasks/TASK-N.reserved (inside the lock), and
  # existing reservations / handoffs / worktrees count toward the max.
  local LAST_N TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  mkdir -p "$TASKS_DIR"
  LAST_N=$( {
      { grep -h '^## \[TASK-' "$PROJECT_ROOT/TODO.md" "$PROJECT_ROOT/TODO-ARCHIVE.md" 2>/dev/null || true; } \
        | sed -E 's/^## \[TASK-([0-9]+)\].*/\1/'
      for f in "$TASKS_DIR"/TASK-*.reserved "$TASKS_DIR"/TASK-*.md "$PROJECT_ROOT/.delegate/worktrees"/TASK-*; do
        [ -e "$f" ] || continue
        f="${f##*/TASK-}"; printf '%s\n' "${f%%[!0-9]*}"
      done
    } | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  local NEXT="TASK-$(( 10#${LAST_N:-0} + 1 ))"
  : > "$TASKS_DIR/$NEXT.reserved"
  ensure_delegate_ignored
  echo "$NEXT"
}

# ── Stop ─────────────────────────────────────────────────────────────────────

cmd_stop() {
  local TASK_ID="${1:?Usage: delegate.sh stop <task-id>}"
  validate_task_id "$TASK_ID"
  validate_delegate_paths "$TASK_ID"
  local PID_FILE="$PROJECT_ROOT/.delegate/tasks/$TASK_ID.pid" PID
  PID=$(cat "$PID_FILE" 2>/dev/null) || PID=""
  if ! task_agent_alive "$TASK_ID" "$PID"; then
    echo "STATE=NOT_RUNNING"
    return 0
  fi
  # Marker first, so status reports STOPPED (deliberate) rather than a crash.
  : > "$PROJECT_ROOT/.delegate/tasks/$TASK_ID.stopped"
  # TERM the process tree, give it up to 10s to exit cleanly, then KILL.
  # kill_tree refuses to signal a PID whose fingerprint no longer matches.
  kill_tree "$TASK_ID" TERM
  local waited=0
  while pid_alive "$PID" && [ "$waited" -lt 100 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  pid_alive "$PID" && kill_tree "$TASK_ID" KILL
  # The supervisor records the exit code once its child is reaped.
  waited=0
  while [ ! -f "$PROJECT_ROOT/.delegate/tasks/$TASK_ID.exitcode" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  echo "STATE=STOPPED"
  echo "PID=$PID"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
# Post-merge teardown. Refuses while the agent runs, and refuses (removing
# nothing) while the branch has commits the current branch lacks or the
# worktree has uncommitted changes — unless --force. Logs and state files under
# .delegate/tasks/ are kept for the record. Merging stays the user's call.

cmd_cleanup() {
  local TASK_ID="" FORCE=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=1 ;;
      *) if [ -z "$TASK_ID" ]; then TASK_ID="$arg"
         else echo "ERROR: unexpected argument: $arg" >&2; return 1; fi ;;
    esac
  done
  [ -n "$TASK_ID" ] || { usage; return 1; }
  validate_task_id "$TASK_ID"
  validate_delegate_paths "$TASK_ID"
  git rev-parse --git-dir &>/dev/null || { echo "ERROR: not a git repository — nothing to clean up." >&2; return 1; }

  local WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID" PID BRANCH="" err
  PID=$(cat "$PROJECT_ROOT/.delegate/tasks/$TASK_ID.pid" 2>/dev/null) || PID=""
  if task_agent_alive "$TASK_ID" "$PID"; then
    echo "ERROR: $TASK_ID agent (pid $PID) is still running — stop it first (delegate.sh stop $TASK_ID)." >&2
    return 1
  fi

  if [ -d "$WORK_DIR" ]; then
    BRANCH=$(git -C "$WORK_DIR" symbolic-ref --short HEAD 2>/dev/null) || BRANCH=""
    [[ "$BRANCH" == */"$TASK_ID" ]] || {
      echo "ERROR: $WORK_DIR is not on a <runtime>/$TASK_ID branch — refusing to remove it." >&2
      return 1
    }
    validate_worktree "$WORK_DIR" "$BRANCH" || return 1
  else
    git worktree prune 2>/dev/null || true
    local matches
    matches=$(git for-each-ref --format='%(refname:short)' "refs/heads/*/$TASK_ID" 2>/dev/null) || matches=""
    if [ "$(printf '%s
' "$matches" | grep -c .)" -gt 1 ]; then
      echo "ERROR: several branches match */$TASK_ID — remove the right one by hand: $(printf '%s' "$matches" | tr '
' ' ')" >&2
      return 1
    fi
    BRANCH="$matches"
  fi
  if [ ! -d "$WORK_DIR" ] && [ -z "$BRANCH" ]; then
    echo "STATE=NOTHING_TO_CLEAN"
    return 0
  fi

  if [ -n "$BRANCH" ] && [ "$FORCE" != 1 ] && ! git merge-base --is-ancestor "$BRANCH" HEAD 2>/dev/null; then
    echo "ERROR: branch $BRANCH has commits that are not merged into the current branch — merge it first (git merge $BRANCH), or pass --force to discard them." >&2
    return 1
  fi
  if [ -d "$WORK_DIR" ]; then
    if [ "$FORCE" = 1 ]; then
      err=$(git worktree remove --force "$WORK_DIR" 2>&1) || { echo "ERROR: could not remove the worktree: ${err##*$'
'}" >&2; return 1; }
    else
      err=$(git worktree remove "$WORK_DIR" 2>&1) || { echo "ERROR: could not remove the worktree (uncommitted changes? use --force to discard them): ${err##*$'
'}" >&2; return 1; }
    fi
  fi
  git worktree prune 2>/dev/null || true
  if [ -n "$BRANCH" ]; then
    if [ "$FORCE" = 1 ]; then
      err=$(git branch -D "$BRANCH" 2>&1) || { echo "ERROR: worktree removed but branch $BRANCH was not: ${err##*$'
'}" >&2; return 1; }
    else
      err=$(git branch -d "$BRANCH" 2>&1) || { echo "ERROR: worktree removed but branch $BRANCH was not: ${err##*$'
'}" >&2; return 1; }
    fi
  fi
  echo "STATE=CLEANED"
  echo "BRANCH=${BRANCH:-none}"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
  status)    shift; cmd_status "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  next-id)   shift; cmd_next_id "$@" ;;
  stop)      shift; cmd_stop "$@" ;;
  cleanup)   shift; cmd_cleanup "$@" ;;
  version|--version) echo "$DELEGATE_VERSION" ;;
  -h|--help) usage; exit 0 ;;
  "")        usage; exit 1 ;;
  *) cmd_launch "$@" ;;
esac
