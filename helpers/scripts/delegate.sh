#!/usr/bin/env bash
# scripts/delegate.sh — tool-agnostic delegation launcher
#
# Handles the mechanical parts of the delegation workflow:
#   1. Validates that the handoff document exists
#   2. Creates (or reuses) an isolated git worktree
#   3. Launches the agent CLI in the background
#   4. Sets up a timeout watchdog
#   5. Writes PID files for monitoring
#
# The CALLING tool (AI or script) is responsible for:
#   - Writing the handoff document before calling this script
#   - Updating TODO.md with the task entry
#   - Monitoring progress and self-healing after launch
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

set -euo pipefail

RUNTIME="${1:?Usage: delegate.sh <runtime> <task-id> [timeout-secs]}"
TASK_ID="${2:?Usage: delegate.sh <runtime> <task-id> [timeout-secs]}"
TIMEOUT_SECS="${3:-1800}"

PROJECT_ROOT="$(pwd)"
TASKS_DIR="$PROJECT_ROOT/.delegate/tasks"
TASK_FILE="$TASKS_DIR/$TASK_ID.md"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/$TASK_ID"
LOG_FILE="$TASKS_DIR/$TASK_ID.log"
PID_FILE="$TASKS_DIR/$TASK_ID.pid"
WATCHDOG_FILE="$TASKS_DIR/$TASK_ID.watchdog.pid"

# ── Preflight ──────────────────────────────────────────────────────────────────

if [ ! -f "$TASK_FILE" ]; then
  cat >&2 <<EOF
ERROR: Handoff document not found: $TASK_FILE
Write the handoff document before calling delegate.sh.
See skills/shared/workflow.md Steps 2–3 for the required format.
EOF
  exit 1
fi

if ! command -v "$RUNTIME" &>/dev/null; then
  cat >&2 <<EOF
ERROR: Runtime '$RUNTIME' not found on PATH.
Install it and ensure it is accessible, then retry.
  opencode  →  npm install -g opencode-ai
  pi        →  bun install -g @earendil-works/pi-coding-agent
  mimo      →  npm install -g @mimo-ai/cli
  codex     →  npm install -g @openai/codex
  hermes    →  see Hermes Agent documentation
  kimi      →  see Kimi Code documentation
  agy       →  see Agy documentation
EOF
  exit 1
fi

mkdir -p "$TASKS_DIR"

# ── Worktree ───────────────────────────────────────────────────────────────────

# Fall back to the project root when isolation isn't possible — the agent must
# see the actual code. An empty plain directory would give it nothing to work on.
if git rev-parse --git-dir &>/dev/null && git rev-parse HEAD &>/dev/null; then
  BRANCH="${RUNTIME}/${TASK_ID}"
  if [ ! -d "$WORK_DIR" ]; then
    git worktree add "$WORK_DIR" -b "$BRANCH" 2>/dev/null || \
      git worktree add "$WORK_DIR" "$BRANCH" 2>/dev/null || \
      { WORK_DIR="$PROJECT_ROOT"; echo "WARN: worktree creation failed — running in project root without isolation" >&2; }
  fi
else
  WORK_DIR="$PROJECT_ROOT"
  echo "WARN: not a git repo — worktree isolation skipped, running in project root" >&2
fi

# ── Launch ─────────────────────────────────────────────────────────────────────

case "$RUNTIME" in

  opencode)
    # Flag name has changed across opencode versions (--dangerously-skip-permissions
    # was replaced by --auto as of v1.17.x) — detect instead of hardcoding.
    # Check the deprecated flag first so --auto wins when a version supports both.
    OPENCODE_HELP=$(opencode run --help 2>&1)
    OPENCODE_AUTO=""
    echo "$OPENCODE_HELP" | grep -q -- "--dangerously-skip-permissions" && OPENCODE_AUTO="--dangerously-skip-permissions"
    echo "$OPENCODE_HELP" | grep -q -- "--auto" && OPENCODE_AUTO="--auto"
    # shellcheck disable=SC2086
    nohup opencode run "Execute the task in the handoff document." \
      --file "$TASK_FILE" \
      --dir  "$WORK_DIR" \
      $OPENCODE_AUTO \
      > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  pi)
    # cd into the worktree directly (one runtime per invocation, so changing
    # the script cwd is safe). This makes $! the real nohup agent PID, not a
    # subshell PID — critical for liveness checks and the watchdog.
    cd "$WORK_DIR"
    nohup pi -p "@$TASK_FILE" "Execute the task in the handoff document." \
      --approve \
      > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  mimo)
    # Build args as an array so paths containing spaces survive expansion
    # (a flat string like "--dir $WORK_DIR" word-splits on the space).
    # The ${arr[@]+...} expansion keeps empty arrays safe under `set -u`
    # on bash 3.2 (macOS default).
    MIMO_HELP=$(mimo run --help 2>&1)
    MIMO_ARGS=() ; MIMO_HAS_FILE=""
    echo "$MIMO_HELP" | grep -q -- "--file" && \
      { MIMO_HAS_FILE=1; MIMO_ARGS+=(--file "$TASK_FILE"); }
    echo "$MIMO_HELP" | grep -q -- "--dir"  && MIMO_ARGS+=(--dir "$WORK_DIR")
    echo "$MIMO_HELP" | grep -q "dangerously-skip-permissions" && \
      MIMO_ARGS+=(--dangerously-skip-permissions)
    if [ -n "$MIMO_HAS_FILE" ]; then
      nohup mimo run "Execute the handoff task." ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"} \
        > "$LOG_FILE" 2>&1 &
    else
      # No --file flag: cd into the worktree so isolation holds. Same reason
      # as pi — $! must be the agent, not a subshell.
      cd "$WORK_DIR"
      nohup mimo run "Read $TASK_FILE and execute the task." ${MIMO_ARGS[@]+"${MIMO_ARGS[@]}"} \
        > "$LOG_FILE" 2>&1 &
    fi
    TASK_PID=$!
    ;;

  hermes)
    # cd into the worktree directly — see pi note above re: $! semantics.
    cd "$WORK_DIR"
    nohup hermes chat \
      -q "Read $TASK_FILE and execute the task described in it. All changes must stay in $WORK_DIR." \
      --yolo --accept-hooks -Q \
      > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  kimi)
    # cd into the worktree directly — see pi note above re: $! semantics.
    cd "$WORK_DIR"
    nohup kimi \
      -p "Read $TASK_FILE and execute the task described in it. All changes must stay in $WORK_DIR." \
      -y \
      > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  codex)
    # codex must be the LAST element of the backgrounded pipeline: $! is the PID
    # of the last pipeline command, so this makes the watchdog and liveness
    # checks target codex itself. (A previous `nohup bash -c '... | codex ...'`
    # wrapper captured the bash PID instead — SIGTERM to bash does not propagate
    # to the piped codex child, so timeouts left codex running.)
    { printf '%s\n\n' "Execute the task described in the handoff document below. Follow all instructions in it exactly."; \
      cat "$TASK_FILE"; } | \
      nohup codex exec -C "$WORK_DIR" \
        -s danger-full-access \
        --dangerously-bypass-approvals-and-sandbox \
        - \
        > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  agy)
    nohup agy \
      --print "Read $TASK_FILE and execute the task described in it. All changes in $WORK_DIR." \
      --add-dir "$WORK_DIR" \
      --dangerously-skip-permissions \
      > "$LOG_FILE" 2>&1 &
    TASK_PID=$!
    ;;

  *)
    echo "ERROR: Unsupported runtime '$RUNTIME'." >&2
    echo "Supported: opencode pi mimo hermes kimi codex agy" >&2
    exit 1
    ;;

esac

# ── PID files ─────────────────────────────────────────────────────────────────

echo "$TASK_PID" > "$PID_FILE"
# Initialise retry counter for parity with the SKILL.md inline launch blocks;
# Step 5 Case 1 reads this file (falls back to 0 if absent, but write it so the
# contract is consistent across both launch paths).
echo 0 > "$TASKS_DIR/$TASK_ID.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30 s grace
(sleep "$TIMEOUT_SECS" && \
 kill -TERM "$TASK_PID" 2>/dev/null && \
 sleep 30 && \
 kill -KILL "$TASK_PID" 2>/dev/null) &
echo $! > "$WATCHDOG_FILE"

# ── Report ────────────────────────────────────────────────────────────────────

echo "PID=$TASK_PID"
echo "LOG=$LOG_FILE"
echo "WORK_DIR=$WORK_DIR"
