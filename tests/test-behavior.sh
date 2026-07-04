#!/usr/bin/env bash
# tests/test-behavior.sh — behavioral tests for delegate.sh
#
# Tests actual execution: runs delegate.sh in isolated sandboxes with mock CLI
# binaries, verifies process/filesystem state (not just text patterns).
#
# Can be sourced by run-tests.sh or run standalone.

# Standalone fallback — define helpers if not already defined by parent
if ! declare -f pass &>/dev/null; then
  PASS=0; FAIL=0
  pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
  fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  _standalone=true
fi

DELEGATE_SH="${DELEGATE_SH:-$PROJECT_ROOT/helpers/scripts/delegate.sh}"
FIXTURES="${FIXTURES:-$PROJECT_ROOT/tests/fixtures/mock-bin}"

# ─── Helper: Wait for mock files to be created ──────────────────────────────────

wait_for_mock_file() {
  local file="$1"
  local timeout_seconds=5
  local interval=0.1
  # Iteration count for a timeout_seconds/interval window — NOT a 1:1 seconds
  # counter. (A prior version incremented this by 1 per 0.1s sleep and compared
  # it directly to a "5" meant as seconds, so it only ever waited 0.5s total —
  # too tight under any real system load, causing intermittent failures.)
  local max_iterations=$(( (timeout_seconds * 10) ))
  local elapsed=0

  while [ ! -f "$file" ] && [ "$elapsed" -lt "$max_iterations" ]; do
    sleep "$interval"
    elapsed=$((elapsed + 1))
  done

  [ -f "$file" ]
}

# ─── Helper: Create a valid handoff document ──────────────────────────────────

create_handoff() {
  local sandbox="$1"
  local task_id="$2"
  local content="${3:-This is a test handoff document for $task_id.}"

  mkdir -p "$sandbox/.delegate/tasks"
  cat > "$sandbox/.delegate/tasks/$task_id.md" <<EOF
# Handoff: $task_id

$content
EOF
}

# ─── Helper: Initialize a git repo in the sandbox ────────────────────────────

init_git_repo() {
  local sandbox="$1"
  cd "$sandbox"
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test User"
  git commit -q --allow-empty -m "initial commit"
}

# ─── Helper: Snapshot the watchdog's sleep child immediately after launch ────
#
# The watchdog subshell delegate.sh backgrounds (`(sleep N && kill ...) &`) is
# reliably alive with its sleep child right after delegate.sh returns, but by
# the time a test's cleanup runs (after its own assertions/greps/waits), the
# subshell has often already exited on its own, orphaning the sleep — which
# then survives, reparented, with no structural link back to it for a later
# `pgrep -P` to find. Capturing the child PID here, immediately post-launch,
# closes that race: cleanup_sandbox kills whatever PID was captured here
# regardless of what has since happened to its original parent.

snapshot_watchdog_children() {
  local sandbox="$1"
  local f pid child
  for f in "$sandbox"/.delegate/tasks/*.watchdog.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      echo "$child" >> "$f.children"
    done
  done
}

# ─── Helper: Clean up sandbox and kill watchdog processes ───────────────────

cleanup_sandbox() {
  local sandbox="$1"
  # Kill all processes associated with this sandbox. The watchdog is a background
  # subshell running `sleep N && kill ... && sleep 30 && kill ...`. Killing only
  # the subshell's own PID orphans the `sleep` it's currently blocked in (it gets
  # reparented, typically to PID 1, and keeps running for up to N+30 seconds).
  # We must kill that child directly too — found via `pgrep -P <watchdog_pid>`,
  # which only matches direct children of THIS watchdog, not sleep processes
  # anywhere else on the system. Do NOT match on command text like "sleep 30"
  # globally — that would kill unrelated processes on the host that happen to
  # share the same duration.
  if [ -d "$sandbox/.delegate/tasks" ]; then
    local f pid child

    # Kill all task processes (these are the actual agent CLIs being run)
    for f in "$sandbox"/.delegate/tasks/*.pid; do
      [ -f "$f" ] || continue
      pid=$(cat "$f" 2>/dev/null)
      [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    done

    # Kill all watchdog subshells, plus their direct child (the sleep currently
    # running inside them) so nothing is left orphaned. Live pgrep -P here is a
    # best-effort second attempt — by cleanup time the watchdog subshell may
    # already be gone (see snapshot_watchdog_children, called right after launch,
    # which is the primary mechanism since it runs before that race window).
    for f in "$sandbox"/.delegate/tasks/*.watchdog.pid; do
      [ -f "$f" ] || continue
      pid=$(cat "$f" 2>/dev/null)
      [ -z "$pid" ] && continue
      for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill -KILL "$child" 2>/dev/null || true
      done
      kill -KILL "$pid" 2>/dev/null || true
    done

    # Kill children snapshotted immediately after launch (see
    # snapshot_watchdog_children) — this is the reliable path, since it
    # captures the watchdog's sleep child before it can be reparented away
    # from a live pgrep -P lookup done later, at cleanup time.
    for f in "$sandbox"/.delegate/tasks/*.watchdog.pid.children; do
      [ -f "$f" ] || continue
      while IFS= read -r child; do
        [ -n "$child" ] && kill -KILL "$child" 2>/dev/null || true
      done < "$f"
    done
  fi
  cd "$PROJECT_ROOT" 2>/dev/null || true
  rm -rf "$sandbox"
}

# ─── Test 1: Missing handoff document → exit 1 ──────────────────────────────

test_missing_handoff() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  # Run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" bash "$DELEGATE_SH" opencode TASK-1 5 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  # Assert
  [ "$exit_code" = "1" ] || return 1
  grep -q "skills/shared/workflow.md" "$tempfile" || return 1
}

# ─── Test 2: Missing runtime → exit 1 with guidance ───────────────────────

test_missing_runtime() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-2"

  # Run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$SANDBOX/bin" bash "$DELEGATE_SH" totally-fake-runtime-xyz TASK-2 5 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  # Assert
  [ "$exit_code" = "1" ] || return 1
  grep -q "not found on PATH" "$tempfile" || return 1
}

# ─── Test 3: Unsupported runtime → exit 1 ───────────────────────────────────

test_unsupported_runtime() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-3"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/unsupported-cli"
  chmod +x "$SANDBOX/bin/unsupported-cli"

  # Run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" bash "$DELEGATE_SH" unsupported-cli TASK-3 5 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  # Assert
  [ "$exit_code" = "1" ] || return 1
  grep -q "Unsupported runtime" "$tempfile" || return 1
}

# ─── Test 4: opencode happy path ─────────────────────────────────────────

test_opencode_happy() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  mkdir -p "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-4"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  # Run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" opencode TASK-4 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  # Basic exit code
  [ "$exit_code" = "0" ] || return 1

  # Check output format
  grep -q "^PID=" "$tempfile" || return 1
  grep -q "^LOG=" "$tempfile" || return 1
  grep -q "^WORK_DIR=" "$tempfile" || return 1

  # Check git worktree was created
  [ -d "$SANDBOX/.delegate/worktrees/TASK-4" ] || return 1
  git -C "$SANDBOX" branch --list "opencode/TASK-4" | grep -q "opencode/TASK-4" || return 1

  # Check retries file
  [ -f "$SANDBOX/.delegate/tasks/TASK-4.retries" ] || return 1
  [ "$(cat "$SANDBOX/.delegate/tasks/TASK-4.retries")" = "0" ] || return 1

  # Check watchdog PID file exists
  [ -f "$SANDBOX/.delegate/tasks/TASK-4.watchdog.pid" ] || return 1

  # Check mock output files
  wait_for_mock_file "$SANDBOX/mockout/opencode.args" || return 1
  grep -qF -- "--file" "$SANDBOX/mockout/opencode.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/tasks/TASK-4.md" "$SANDBOX/mockout/opencode.args" || return 1
  grep -qF -- "--dir" "$SANDBOX/mockout/opencode.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/worktrees/TASK-4" "$SANDBOX/mockout/opencode.args" || return 1
  grep -qF -- "--auto" "$SANDBOX/mockout/opencode.args" || return 1

  # Confirm the log actually captured the mock's output once it finished.
  # The mock writes its .status file, THEN echoes its completion line to
  # stdout (captured into the log) — poll the log too, not just .status,
  # since there's a real (if small) gap between those two writes.
  local waited=0
  while [ "$waited" -lt 50 ]; do
    if grep -q "Mock opencode completed successfully\|DONE" "$SANDBOX/.delegate/tasks/TASK-4.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -q "Mock opencode completed successfully\|DONE" "$SANDBOX/.delegate/tasks/TASK-4.log" || return 1
}

# ─── Test 5: PID-capture regression test for pi ──────────────────────────

test_pi_pid_capture() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-5"
  cp "$FIXTURES/pi" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/pi"

  # Run with MOCK_HANG (avoid command substitution to prevent bash 3.2 hang)
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" pi TASK-5 120 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Extract PID
  local task_pid
  task_pid=$(cat "$SANDBOX/.delegate/tasks/TASK-5.pid" 2>/dev/null)
  [ -n "$task_pid" ] || return 1

  # Verify PID is alive
  kill -0 "$task_pid" 2>/dev/null || return 1

  # Verify heartbeat is advancing (use 1.5s sleep to ensure we cross a second boundary)
  local hb1 hb2
  hb1=$(cat "$SANDBOX/mockout/pi.heartbeat" 2>/dev/null)
  sleep 1.5
  hb2=$(cat "$SANDBOX/mockout/pi.heartbeat" 2>/dev/null)
  [ "$hb1" != "$hb2" ] || return 1

  # Kill and verify TERM trap
  kill -TERM "$task_pid" 2>/dev/null
  sleep 1
  grep -q "KILLED" "$SANDBOX/mockout/pi.status" || return 1
}

# ─── Test 6: PID-capture for hermes ──────────────────────────────────────

test_hermes_pid_capture() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-6"
  cp "$FIXTURES/hermes" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/hermes"

  # Run (avoid command substitution)
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" hermes TASK-6 120 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Extract PID
  local task_pid
  task_pid=$(cat "$SANDBOX/.delegate/tasks/TASK-6.pid" 2>/dev/null)
  [ -n "$task_pid" ] || return 1

  # Verify alive
  kill -0 "$task_pid" 2>/dev/null || return 1

  # Verify heartbeat (use 1.5s sleep to ensure we cross a second boundary)
  local hb1 hb2
  hb1=$(cat "$SANDBOX/mockout/hermes.heartbeat" 2>/dev/null)
  sleep 1.5
  hb2=$(cat "$SANDBOX/mockout/hermes.heartbeat" 2>/dev/null)
  [ "$hb1" != "$hb2" ] || return 1

  # Kill and verify TERM trap
  kill -TERM "$task_pid" 2>/dev/null
  sleep 1
  grep -q "KILLED" "$SANDBOX/mockout/hermes.status" || return 1
}

# ─── Test 7: PID-capture for kimi ───────────────────────────────────────

test_kimi_pid_capture() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-7"
  cp "$FIXTURES/kimi" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/kimi"

  # Run (avoid command substitution)
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" kimi TASK-7 120 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Extract PID
  local task_pid
  task_pid=$(cat "$SANDBOX/.delegate/tasks/TASK-7.pid" 2>/dev/null)
  [ -n "$task_pid" ] || return 1

  # Verify alive
  kill -0 "$task_pid" 2>/dev/null || return 1

  # Verify heartbeat (use 1.5s sleep to ensure we cross a second boundary)
  local hb1 hb2
  hb1=$(cat "$SANDBOX/mockout/kimi.heartbeat" 2>/dev/null)
  sleep 1.5
  hb2=$(cat "$SANDBOX/mockout/kimi.heartbeat" 2>/dev/null)
  [ "$hb1" != "$hb2" ] || return 1

  # Kill and verify TERM trap
  kill -TERM "$task_pid" 2>/dev/null
  sleep 1
  grep -q "KILLED" "$SANDBOX/mockout/kimi.status" || return 1
}

# ─── Test 8: mimo — --file supported branch ──────────────────────────

test_mimo_file_supported() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-8"
  cp "$FIXTURES/mimo" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/mimo"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_MIMO_HAS_FILE=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" mimo TASK-8 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/mimo.cwd" || return 1

  # Check cwd
  local cwd
  cwd=$(cat "$SANDBOX/mockout/mimo.cwd" 2>/dev/null)
  [ "$cwd" = "$SANDBOX" ] || return 1

  # Check .args
  wait_for_mock_file "$SANDBOX/mockout/mimo.args" || return 1
  grep -qF -- "--file" "$SANDBOX/mockout/mimo.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/tasks/TASK-8.md" "$SANDBOX/mockout/mimo.args" || return 1
  grep -qF -- "--dir" "$SANDBOX/mockout/mimo.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/worktrees/TASK-8" "$SANDBOX/mockout/mimo.args" || return 1
}

# ─── Test 9: mimo — --file NOT supported, cd-fallback ──────────────────

test_mimo_file_not_supported() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-9"
  cp "$FIXTURES/mimo" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/mimo"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" mimo TASK-9 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/mimo.cwd" || return 1

  # Check cwd is worktree
  local cwd
  cwd=$(cat "$SANDBOX/mockout/mimo.cwd" 2>/dev/null)
  [ "$cwd" = "$SANDBOX/.delegate/worktrees/TASK-9" ] || return 1

  # Check .args - --file must NOT be present
  wait_for_mock_file "$SANDBOX/mockout/mimo.args" || return 1
  if grep -qF -- "--file" "$SANDBOX/mockout/mimo.args"; then
    return 1
  fi
}

# ─── Test 10: codex — stdin framing ──────────────────────────────────

test_codex_stdin_framing() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  local unique_marker="UNIQUE_MARKER_12345"
  create_handoff "$SANDBOX" "TASK-10" "This handoff contains $unique_marker for testing."
  cp "$FIXTURES/codex" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/codex"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" codex TASK-10 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/codex.stdin" || return 1

  # Check stdin capture
  [ -f "$SANDBOX/mockout/codex.stdin" ] || return 1

  # Check framing
  head -1 "$SANDBOX/mockout/codex.stdin" | grep -q "Execute the task described in the handoff document below. Follow all instructions in it exactly." || return 1

  # Check marker
  grep -q "$unique_marker" "$SANDBOX/mockout/codex.stdin" || return 1
}

# ─── Test 11: agy — no-cd, --add-dir behavior ──────────────────────────

test_agy_add_dir() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-11"
  cp "$FIXTURES/agy" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/agy"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" agy TASK-11 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/agy.cwd" || return 1

  # Check cwd
  local cwd
  cwd=$(cat "$SANDBOX/mockout/agy.cwd" 2>/dev/null)
  [ "$cwd" = "$SANDBOX" ] || return 1

  # Check .args
  wait_for_mock_file "$SANDBOX/mockout/agy.args" || return 1
  grep -qF -- "--add-dir" "$SANDBOX/mockout/agy.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/worktrees/TASK-11" "$SANDBOX/mockout/agy.args" || return 1
  grep -qF -- "--print" "$SANDBOX/mockout/agy.args" || return 1
}

# ─── Test 12: hermes — cd + absolute path ──────────────────────────

test_hermes_absolute_path() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-12"
  cp "$FIXTURES/hermes" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/hermes"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" hermes TASK-12 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/hermes.cwd" || return 1

  # Check cwd is worktree
  local cwd
  cwd=$(cat "$SANDBOX/mockout/hermes.cwd" 2>/dev/null)
  [ "$cwd" = "$SANDBOX/.delegate/worktrees/TASK-12" ] || return 1

  # Check .args
  wait_for_mock_file "$SANDBOX/mockout/hermes.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/tasks/TASK-12.md" "$SANDBOX/mockout/hermes.args" || return 1
}

# ─── Test 13: kimi — cd + absolute path ───────────────────────────

test_kimi_absolute_path() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-13"
  cp "$FIXTURES/kimi" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/kimi"

  # Run
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" kimi TASK-13 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for mock files to be created
  wait_for_mock_file "$SANDBOX/mockout/kimi.cwd" || return 1

  # Check cwd is worktree
  local cwd
  cwd=$(cat "$SANDBOX/mockout/kimi.cwd" 2>/dev/null)
  [ "$cwd" = "$SANDBOX/.delegate/worktrees/TASK-13" ] || return 1

  # Check .args
  wait_for_mock_file "$SANDBOX/mockout/kimi.args" || return 1
  grep -qF -- "$SANDBOX/.delegate/tasks/TASK-13.md" "$SANDBOX/mockout/kimi.args" || return 1
}

# ─── Test 14: Not a git repo ───────────────────────────────────────────

test_not_git_repo() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup (no git init)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/.delegate/tasks"
  create_handoff "$SANDBOX" "TASK-14"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  # Run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 bash "$DELEGATE_SH" opencode TASK-14 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Check warning
  grep -q "not a git repo" "$tempfile" || return 1

  # Check worktree exists
  [ -d "$SANDBOX/.delegate/worktrees/TASK-14" ] || return 1
}

# ─── Test 15: Worktree reuse ──────────────────────────────────────────

test_worktree_reuse() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-15"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  # First run
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out1.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 bash "$DELEGATE_SH" opencode TASK-15 30 < /dev/null > "$tempfile" 2>&1
  local exit_code1=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code1" = "0" ] || return 1

  # Second run
  local tempfile2=$SANDBOX/test_out2.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 bash "$DELEGATE_SH" opencode TASK-15 30 < /dev/null > "$tempfile2" 2>&1
  local exit_code2=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code2" = "0" ] || return 1
}

# ─── Test 16: Watchdog SIGTERM ───────────────────────────────────────

test_watchdog_sigterm() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  # Setup
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-16"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  # Run with short timeout and MOCK_HANG
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" opencode TASK-16 2 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Wait for watchdog to fire. Re-snapshot on every poll, not just once: this
  # test deliberately waits past the watchdog's own timeout, so the watchdog
  # subshell transitions from its first `sleep 2` into `kill -TERM ... && sleep
  # 30` (the SIGKILL grace period) DURING this wait — a new child process with
  # a different PID than the one snapshot_watchdog_children caught right after
  # launch. Polling here catches that second child too, so cleanup can kill it.
  local waited=0
  while [ "$waited" -lt 40 ]; do
    snapshot_watchdog_children "$SANDBOX"
    [ -f "$SANDBOX/mockout/opencode.status" ] && grep -q "KILLED" "$SANDBOX/mockout/opencode.status" 2>/dev/null && break
    sleep 0.1
    waited=$((waited + 1))
  done
  snapshot_watchdog_children "$SANDBOX"

  # Check status
  [ -f "$SANDBOX/mockout/opencode.status" ] || return 1
  grep -q "KILLED" "$SANDBOX/mockout/opencode.status" || return 1
}

# ─── Main: Run all tests ──────────────────────────────────────────────────────

test_missing_handoff && pass "Missing handoff document → exit 1 with correct error" || fail "Missing handoff document → exit 1 with correct error"
test_missing_runtime && pass "Missing runtime → exit 1 with install guidance" || fail "Missing runtime → exit 1 with install guidance"
test_unsupported_runtime && pass "Unsupported runtime → exit 1" || fail "Unsupported runtime → exit 1"
test_opencode_happy && pass "opencode happy path — full behavioral check" || fail "opencode happy path — full behavioral check"
test_pi_pid_capture && pass "PID-capture regression test for pi" || fail "PID-capture regression test for pi"
test_hermes_pid_capture && pass "PID-capture regression test for hermes" || fail "PID-capture regression test for hermes"
test_kimi_pid_capture && pass "PID-capture regression test for kimi" || fail "PID-capture regression test for kimi"
test_mimo_file_supported && pass "mimo — \`--file\` supported branch" || fail "mimo — \`--file\` supported branch"
test_mimo_file_not_supported && pass "mimo — \`--file\` NOT supported, cd-fallback branch" || fail "mimo — \`--file\` NOT supported, cd-fallback branch"
test_codex_stdin_framing && pass "codex — stdin framing" || fail "codex — stdin framing"
test_agy_add_dir && pass "agy — no-cd, \`--add-dir\` behavior" || fail "agy — no-cd, \`--add-dir\` behavior"
test_hermes_absolute_path && pass "hermes — cd + absolute path in prompt" || fail "hermes — cd + absolute path in prompt"
test_kimi_absolute_path && pass "kimi — cd + absolute path in prompt" || fail "kimi — cd + absolute path in prompt"
test_not_git_repo && pass "Not a git repo → fallback to plain directory" || fail "Not a git repo → fallback to plain directory"
test_worktree_reuse && pass "Worktree reuse — second launch for same TASK-N" || fail "Worktree reuse — second launch for same TASK-N"
test_watchdog_sigterm && pass "Watchdog SIGTERM fires on timeout" || fail "Watchdog SIGTERM fires on timeout"

# ─── Standalone summary ───────────────────────────────────────────────────

if [ "${_standalone:-false}" = "true" ]; then
  echo ""
  echo "════════════════════════════════════════"
  echo "  Behavior Tests: $PASS passed, $FAIL failed"
  echo "════════════════════════════════════════"

  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
fi
