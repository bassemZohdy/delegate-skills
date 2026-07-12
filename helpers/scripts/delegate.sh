#!/usr/bin/env bash
# scripts/delegate.sh — tool-agnostic delegation launcher, monitor, and helpers
#
# Subcommands:
#   delegate.sh <runtime> <task-id> [timeout-secs]   Launch a task (default/legacy form)
#   delegate.sh status <task-id>                     Machine-readable status
#   delegate.sh verify <task-id>                     Run the handoff's verification block
#   delegate.sh reconcile                            Report stale in_progress TODO.md entries
#   delegate.sh next-id                               Atomically allocate the next TASK-N
#
# ── Launch ───────────────────────────────────────────────────────────────────
# Handles the mechanical parts of delegation:
#   1. Validates the handoff document exists
#   2. Creates (or reuses) an isolated git worktree — falls back to the
#      project root if isolation isn't possible (never an empty directory,
#      which would give the agent nothing to work on)
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
#   bash delegate.sh <runtime> <task-id> [timeout-seconds]
#
# Arguments:
#   runtime         — opencode | pi | mimo | hermes | kimi | codex | agy
#   task-id         — TASK-N (e.g. TASK-1, TASK-3)
#   timeout-seconds — seconds before the watchdog kills the agent (default: 1800)
#
# The handoff document must already exist at:
#   .delegate/tasks/<task-id>.md
#
# Output (printed to stdout, one per line):
#   PID=<agent process ID>
#   LOG=<absolute path to log file>
#   WORK_DIR=<absolute path to worktree>
#
# Exit codes:
#   0 = agent launched successfully
#   1 = runtime not found, handoff missing, or unsupported runtime
#
# ── Files written under .delegate/tasks/ ────────────────────────────────────
#   TASK-N.pid              real agent process id — signal/inspect this one
#   TASK-N.log               agent's combined stdout/stderr
#   TASK-N.retries           self-healing retry counter (maintained by the caller)
#   TASK-N.watchdog.pid      supervisor process id (kill this to force-abandon
#                            a task early; not needed on normal completion —
#                            the supervisor cancels its own timer)
#   TASK-N.exitcode          agent's real exit code, written once it exits
#   TASK-N.fingerprint       best-effort process identity (guards PID reuse)
#   TASK-N.pgid              process-group id, only written when verified safe
#   TASK-N.supervisor.sh     the generated supervisor script (kept for inspection)
#   TASK-N.log.size          last-seen log size, used by `status` for stall detection
#   TASK-N.lastpoll          mtime marker, used by `status` as a second stall signal
#   TASK-N.verify.log        output of the last `verify` run

set -euo pipefail

PROJECT_ROOT="$(pwd)"

# ── Shared helpers ───────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage:
  delegate.sh <runtime> <task-id> [timeout-secs]   Launch a task
  delegate.sh status <task-id>                     Print machine-readable status
  delegate.sh verify <task-id>                     Run the handoff's verification block
  delegate.sh reconcile                            Report stale in_progress TODO.md entries
  delegate.sh next-id                               Allocate the next TASK-N (lock-protected)
EOF
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

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

# Children of $1, via a fixed-format `ps -ef` fallback (used when neither
# pkill nor `ps -eo pid=,ppid=` is available).
_ps_children_fixed() {
  local ppid="$1"
  ps -ef 2>/dev/null | awk -v p="$ppid" '
    NR==1 { for (i=1;i<=NF;i++) { if (toupper($i)=="PID") pidcol=i; if (toupper($i)=="PPID") ppidcol=i }; next }
    ppidcol && $ppidcol==p { print $pidcol }'
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

  # Children first (covers agents that spawn helper processes), via whichever
  # child-lookup mechanism the platform provides.
  if command -v pkill &>/dev/null; then
    pkill "-$sig" -P "$pid" 2>/dev/null || true
  else
    local children
    children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p {print $1}')
    [ -z "$children" ] && children=$(_ps_children_fixed "$pid")
    if [ -n "$children" ]; then
      printf '%s\n' "$children" | while read -r child; do kill "-$sig" "$child" 2>/dev/null || true; done
    fi
  fi

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
  local RUNTIME="${1:?Usage: delegate.sh <runtime> <task-id> [timeout-secs]}"
  local TASK_ID="${2:?Usage: delegate.sh <runtime> <task-id> [timeout-secs]}"
  local TIMEOUT_SECS="${3:-1800}"

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

  # ── Preflight ──────────────────────────────────────────────────────────
  if [ ! -f "$TASK_FILE" ]; then
    cat >&2 <<EOF
ERROR: Handoff document not found: $TASK_FILE
Write the handoff document before calling delegate.sh.
See skills/shared/workflow.md Steps 2-3 for the required format.
EOF
    exit 1
  fi

  if ! command -v "$RUNTIME" &>/dev/null; then
    cat >&2 <<EOF
ERROR: Runtime '$RUNTIME' not found on PATH.
Install it and ensure it is accessible, then retry.
  opencode  ->  npm install -g opencode-ai
  pi        ->  bun install -g @earendil-works/pi-coding-agent
  mimo      ->  npm install -g @mimo-ai/cli
  codex     ->  npm install -g @openai/codex
  hermes    ->  see Hermes Agent documentation
  kimi      ->  see Kimi Code documentation
  agy       ->  see Agy documentation
EOF
    exit 1
  fi

  mkdir -p "$TASKS_DIR"

  # ── Worktree ───────────────────────────────────────────────────────────
  # Fall back to the project root when isolation isn't possible — the agent
  # must see the actual code. An empty plain directory would give it nothing.
  if git rev-parse --git-dir &>/dev/null && git rev-parse HEAD &>/dev/null; then
    local BRANCH="${RUNTIME}/${TASK_ID}"
    if [ ! -d "$WORK_DIR" ]; then
      git worktree add "$WORK_DIR" -b "$BRANCH" 2>/dev/null || \
        git worktree add "$WORK_DIR" "$BRANCH" 2>/dev/null || \
        { WORK_DIR="$PROJECT_ROOT"; echo "WARN: worktree creation failed — running in project root without isolation" >&2; }
    fi
  else
    WORK_DIR="$PROJECT_ROOT"
    echo "WARN: not a git repo — worktree isolation skipped, running in project root" >&2
  fi

  # setsid gives the agent its own session/process-group for free when
  # available; skipped gracefully otherwise (e.g. Git Bash on Windows, which
  # typically lacks it) — kill_tree still works via its child-scan fallback,
  # just without the process-group layer.
  local SETSID=""
  command -v setsid &>/dev/null && SETSID="setsid"

  # ── Resolve the per-runtime command as a safely-quoted string ───────────
  # Built once here (fast, synchronous — help-flag detection must run before
  # backgrounding) then embedded into the supervisor script below via
  # `printf %q`, so paths/args containing spaces or special characters
  # survive being written to a file and re-parsed by a fresh bash process.
  local INNER_CMD=""   # the command line the supervisor executes and waits on
  local CD_LINE=""      # optional `cd "$WORK_DIR"` statement (own line, NOT joined via && —
                         # backgrounding a `cd X && cmd &` compound makes bash fork a wrapper
                         # subshell for the whole list, so $! becomes the wrapper's pid instead
                         # of the real agent's. A bare cd on its own line, then a plain `cmd &`,
                         # keeps $! pointing at the real process.
                         # prefix for runtimes with no --dir flag

  case "$RUNTIME" in

    opencode)
      local OPENCODE_HELP OPENCODE_AUTO=""
      OPENCODE_HELP=$(opencode run --help 2>&1) || true
      # Deprecated flag checked first so --auto wins when a version supports both.
      echo "$OPENCODE_HELP" | grep -q -- "--dangerously-skip-permissions" && OPENCODE_AUTO="--dangerously-skip-permissions"
      echo "$OPENCODE_HELP" | grep -q -- "--auto" && OPENCODE_AUTO="--auto"
      local args=($SETSID nohup opencode run "Execute the task in the handoff document." --file "$TASK_FILE" --dir "$WORK_DIR")
      [ -n "$OPENCODE_AUTO" ] && args+=("$OPENCODE_AUTO")
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    pi)
      CD_LINE="cd $(printf '%q' "$WORK_DIR")
"
      local args=($SETSID nohup pi -p "@$TASK_FILE" "Execute the task in the handoff document." --approve)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    mimo)
      local MIMO_HELP MIMO_ARGS=() MIMO_HAS_FILE=""
      MIMO_HELP=$(mimo run --help 2>&1) || true
      echo "$MIMO_HELP" | grep -q -- "--file" && { MIMO_HAS_FILE=1; MIMO_ARGS+=(--file "$TASK_FILE"); }
      echo "$MIMO_HELP" | grep -q -- "--dir"  && MIMO_ARGS+=(--dir "$WORK_DIR")
      echo "$MIMO_HELP" | grep -q "dangerously-skip-permissions" && MIMO_ARGS+=(--dangerously-skip-permissions)
      if [ -n "$MIMO_HAS_FILE" ]; then
        local args=($SETSID nohup mimo run "Execute the handoff task." ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"})
      else
        CD_LINE="cd $(printf '%q' "$WORK_DIR")
"
        local args=($SETSID nohup mimo run "Read $TASK_FILE and execute the task." ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"})
      fi
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    hermes)
      CD_LINE="cd $(printf '%q' "$WORK_DIR")
"
      local args=($SETSID nohup hermes chat -q "Read $TASK_FILE and execute the task described in it. All changes must stay in $WORK_DIR." --yolo --accept-hooks -Q)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    kimi)
      CD_LINE="cd $(printf '%q' "$WORK_DIR")
"
      local args=($SETSID nohup kimi -p "Read $TASK_FILE and execute the task described in it. All changes must stay in $WORK_DIR." -y)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    codex)
      # codex is expressed as a pipeline: a framing printf + cat piped into
      # codex. Both stages are quoted independently and rejoined with a
      # literal `|` — the supervisor's `$!` after backgrounding this whole
      # line is codex's own PID (last command in the pipeline), which is
      # what makes an accurate `wait` possible below.
      local pre=(printf '%s\n\n' "Execute the task described in the handoff document below. Follow all instructions in it exactly.")
      local pre_q catq codexq
      pre_q=$(printf '%q ' "${pre[@]}")
      catq=$(printf '%q ' cat "$TASK_FILE")
      local codex_args=($SETSID nohup codex exec -C "$WORK_DIR" -s danger-full-access --dangerously-bypass-approvals-and-sandbox -)
      codexq=$(printf '%q ' "${codex_args[@]}")
      INNER_CMD="{ $pre_q; $catq; } | $codexq"
      ;;

    agy)
      local args=($SETSID nohup agy --print "Read $TASK_FILE and execute the task described in it. All changes in $WORK_DIR." --add-dir "$WORK_DIR" --dangerously-skip-permissions)
      INNER_CMD=$(printf '%q ' "${args[@]}")
      ;;

    *)
      echo "ERROR: Unsupported runtime '$RUNTIME'." >&2
      echo "Supported: opencode pi mimo hermes kimi codex agy" >&2
      exit 1
      ;;

  esac

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

( sleep "\$TIMEOUT_SECS"
  kill -TERM "\$RUNTIME_PID" 2>/dev/null
  sleep 30
  kill -KILL "\$RUNTIME_PID" 2>/dev/null ) &
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
  # call the same Cygwin/MSYS-safe ps fallback used elsewhere in this script,
  # without duplicating the awk logic in the generated file.
  export -f _ps_fixed_field

  # ── Launch the supervisor, nohup'd so it survives the calling session ───
  nohup bash "$SUP_FILE" > "$LOG_FILE" 2>&1 &
  local SUPERVISOR_PID=$!
  echo "$SUPERVISOR_PID" > "$WATCHDOG_FILE"

  # Initialise retry counter for parity with the SKILL.md inline launch
  # blocks; self-healing Case 1 reads this file (falls back to 0 if absent,
  # but write it so the contract is consistent across both launch paths).
  echo 0 > "$TASKS_DIR/$TASK_ID.retries"

  # Wait for the supervisor to record the real agent PID before reporting —
  # callers read PID_FILE immediately after this script returns.
  local waited=0
  while [ ! -s "$PID_FILE" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  # ── Report ────────────────────────────────────────────────────────────
  echo "PID=$(cat "$PID_FILE" 2>/dev/null || echo unknown)"
  echo "LOG=$LOG_FILE"
  echo "WORK_DIR=$WORK_DIR"
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
  local TASK_ID="${1:?Usage: delegate.sh status <task-id>}"
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

  if [ -n "$PID" ] && pid_alive "$PID"; then
    # Second liveness signal alongside log growth: any file in the worktree
    # touched more recently than our own last poll marker means the agent is
    # doing something even if it hasn't written to the log this cycle (e.g.
    # buffered stdout, or a long silent compile) — avoids killing a healthy
    # but quiet agent on log size alone.
    local MTIME_MARKER="$TASKS_DIR/$TASK_ID.lastpoll"
    local FS_ACTIVITY="unknown"
    if [ -d "$WORK_DIR" ]; then
      if [ -f "$MTIME_MARKER" ]; then
        if find "$WORK_DIR" -newer "$MTIME_MARKER" -type f 2>/dev/null | grep -q .; then
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

  # Process is gone — classify using the real exit code when we have one.
  if [ -f "$EXITCODE_FILE" ]; then
    local CODE
    CODE=$(cat "$EXITCODE_FILE" 2>/dev/null) || CODE=""
    if [ "$CODE" = "0" ]; then
      echo "STATE=EXITED_OK"
    else
      echo "STATE=EXITED_FAILED"
      echo "EXITCODE=$CODE"
    fi
  elif [ "$LOG_SIZE" -lt 500 ]; then
    echo "STATE=LAUNCH_FAILED"
  else
    echo "STATE=EXITED_UNKNOWN"
  fi
  echo "PID=$PID"
  echo "LOG_SIZE=$LOG_SIZE"
  echo "RETRIES=$RETRIES"
}

# ── Verify ───────────────────────────────────────────────────────────────────

cmd_verify() {
  local TASK_ID="${1:?Usage: delegate.sh verify <task-id>}"
  local TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
  local TASK_FILE="$TASKS_DIR/$TASK_ID.md"
  local WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID"
  [ -d "$WORK_DIR" ] || WORK_DIR="$PROJECT_ROOT"

  if [ ! -f "$TASK_FILE" ]; then
    echo "ERROR: handoff not found: $TASK_FILE" >&2
    return 1
  fi

  # Extract the fenced ```bash block under "## Verification Expectations".
  local BLOCK
  BLOCK=$(awk '
    /^## Verification Expectations/ { infield=1; next }
    infield && /^## / { infield=0 }
    infield && /^```bash/ { incode=1; next }
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
  ( cd "$WORK_DIR" && bash -c "$BLOCK" ) > "$VERIFY_LOG" 2>&1 || CODE=$?

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
    if [ -z "$PID" ] || ! pid_alive "$PID"; then
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
  local LOCK_DIR="$PROJECT_ROOT/.delegate/todo.lock"
  local STALE_AFTER=30   # seconds — a lock dir older than this is assumed
                         # orphaned by a crashed process, not a live holder.

  mkdir -p "$PROJECT_ROOT/.delegate"

  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -d "$LOCK_DIR" ]; then
      local mtime age
      mtime=$(date -r "$LOCK_DIR" +%s 2>/dev/null) || mtime=""
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
  local LAST_N
  LAST_N=$( { grep -h '^## \[TASK-' "$PROJECT_ROOT/TODO.md" "$PROJECT_ROOT/TODO-ARCHIVE.md" 2>/dev/null || true; } \
    | sed -E 's/^## \[TASK-([0-9]+)\].*/\1/' | sort -n | tail -1)
  echo "TASK-$(( ${LAST_N:-0} + 1 ))"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
  status)    shift; cmd_status "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  next-id)   shift; cmd_next_id "$@" ;;
  ""|-h|--help) usage; exit 1 ;;
  *) cmd_launch "$@" ;;
esac
