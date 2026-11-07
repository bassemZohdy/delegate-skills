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

# Windows CI may supply TMPDIR as D:/... while pwd and launcher paths use /d/....
# Allocate fixtures in the same physical Bash namespace as the process under test.
export TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

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
  # Every fixture is allocated by mktemp. Resolve and check its boundary before
  # any recursive cleanup, including on Windows Git Bash.
  local temp_root resolved
  # RETURN traps may run again when this sourced file returns to its caller.
  # A fixture already removed by the first cleanup is a harmless no-op.
  if [ ! -e "$sandbox" ] && [ ! -L "$sandbox" ]; then
    return 0
  fi
  temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 1
  [ ! -L "$sandbox" ] && [ -d "$sandbox" ] || return 1
  resolved=$(cd "$sandbox" && pwd -P) || return 1
  case "$resolved" in "$temp_root"/*) ;; *)
    echo "ERROR: refusing cleanup outside fixture temp root: $resolved" >&2
    return 1 ;;
  esac
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
  rm -rf -- "$resolved"
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
  grep -q "workflow.md" "$tempfile" || return 1
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
  grep -qF -- "--auto" "$SANDBOX/mockout/opencode.args" && return 1

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
  [ "$cwd" = "$SANDBOX/.delegate/worktrees/TASK-8" ] || return 1

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

  # The recorded PID must be codex's OWN pid, not a wrapper shell's — otherwise
  # the watchdog's SIGTERM never reaches codex (bash doesn't forward it to
  # pipeline children).
  wait_for_mock_file "$SANDBOX/mockout/codex.pid" || return 1
  [ "$(cat "$SANDBOX/.delegate/tasks/TASK-10.pid")" = "$(cat "$SANDBOX/mockout/codex.pid")" ] || return 1
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
  [ "$cwd" = "$SANDBOX/.delegate/worktrees/TASK-11" ] || return 1

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
  mkdir -p "$SANDBOX/mockout"
  cd "$SANDBOX"
  local tempfile=$SANDBOX/test_out.txt
  DELEGATE_ALLOW_UNISOLATED=1 PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" bash "$DELEGATE_SH" opencode TASK-14 30 < /dev/null > "$tempfile" 2>&1
  local exit_code=$?
  snapshot_watchdog_children "$SANDBOX"

  [ "$exit_code" = "0" ] || return 1

  # Check warning
  grep -q "not a git repo" "$tempfile" || return 1

  # Must fall back to the PROJECT ROOT, not an empty plain directory — an
  # agent launched in a blank worktrees/TASK-14 dir would see no project files.
  grep -q "^WORK_DIR=" "$tempfile" || return 1
  grep "^WORK_DIR=" "$tempfile" | grep -q "worktrees/TASK-14" && return 1
  [ -d "$SANDBOX/.delegate/worktrees/TASK-14" ] && return 1

  # The mock must have received --dir pointing at the project root
  wait_for_mock_file "$SANDBOX/mockout/opencode.args" || return 1
  grep -A1 -- "--dir" "$SANDBOX/mockout/opencode.args" | grep -q "worktrees/TASK-14" && return 1
  return 0
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
  # The timer fires at 2s, then walks the process table before signalling
  # (slow ps on Git Bash, slower under suite load): allow 8s, not 4s.
  local waited=0
  while [ "$waited" -lt 80 ]; do
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

# ─── Test 17: real exit code capture ────────────────────────────────────

test_exit_code_capture() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-17"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-17 30 < /dev/null > "$SANDBOX/test_out.txt" 2>&1
  [ "$?" = "0" ] || return 1
  snapshot_watchdog_children "$SANDBOX"

  # Mock completes normally (exit 0) — wait for it to actually finish.
  wait_for_mock_file "$SANDBOX/mockout/opencode.status" || return 1
  local waited=0
  while [ ! -f "$SANDBOX/.delegate/tasks/TASK-17.exitcode" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
  done

  [ -f "$SANDBOX/.delegate/tasks/TASK-17.exitcode" ] || return 1
  [ "$(cat "$SANDBOX/.delegate/tasks/TASK-17.exitcode")" = "0" ] || return 1

  # The watchdog must have self-cancelled — no lingering supervisor/timer.
  local wpid
  wpid=$(cat "$SANDBOX/.delegate/tasks/TASK-17.watchdog.pid" 2>/dev/null)
  sleep 1
  kill -0 "$wpid" 2>/dev/null && return 1

  local status_out
  status_out=$(bash "$DELEGATE_SH" status TASK-17)
  echo "$status_out" | grep -q "^STATE=EXITED_OK$" || return 1
}

# ─── Test 18: status reports failure exit codes ─────────────────────────

test_status_failed_exitcode() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-18"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"

  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-18 2 < /dev/null > "$SANDBOX/test_out.txt" 2>&1
  [ "$?" = "0" ] || return 1
  snapshot_watchdog_children "$SANDBOX"

  # Timeout fires (2s), watchdog TERMs the mock, which exits 143.
  local waited=0
  while [ ! -f "$SANDBOX/.delegate/tasks/TASK-18.exitcode" ] && [ "$waited" -lt 100 ]; do
    snapshot_watchdog_children "$SANDBOX"
    sleep 0.1; waited=$((waited + 1))
  done
  snapshot_watchdog_children "$SANDBOX"

  [ -f "$SANDBOX/.delegate/tasks/TASK-18.exitcode" ] || return 1
  local code
  code=$(cat "$SANDBOX/.delegate/tasks/TASK-18.exitcode")
  [ "$code" != "0" ] || return 1

  # The supervisor's timer recorded that it fired; status reports a timeout
  # (not a generic failure) and still carries the real exit code.
  [ -f "$SANDBOX/.delegate/tasks/TASK-18.timedout" ] || return 1
  local status_out
  status_out=$(bash "$DELEGATE_SH" status TASK-18)
  echo "$status_out" | grep -q "^STATE=TIMED_OUT$" || return 1
  echo "$status_out" | grep -q "^EXITCODE=$code$" || return 1
}

# ─── Test 18b: nonzero exits classify as EXITED_FAILED / LAUNCH_FAILED ──

test_status_failure_classes() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-40"
  create_handoff "$SANDBOX" "TASK-41"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"

  # Verbose output then exit 3 → a real failure after doing work.
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_EXIT=3 MOCK_VERBOSE=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-40 30 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-40.exitcode" || return 1
  local out
  out=$(bash "$DELEGATE_SH" status TASK-40)
  echo "$out" | grep -q "^STATE=EXITED_FAILED$" || return 1
  echo "$out" | grep -q "^EXITCODE=3$" || return 1

  # Near-silent exit 2 → startup failure (Case 1), still with the real code.
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_EXIT=2 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-41 30 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-41.exitcode" || return 1
  out=$(bash "$DELEGATE_SH" status TASK-41)
  echo "$out" | grep -q "^STATE=LAUNCH_FAILED$" || return 1
  echo "$out" | grep -q "^EXITCODE=2$" || return 1
}

# ─── Test 18c: relaunch keeps retries, rotates log, refuses while running ─

test_relaunch_semantics() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-42"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"
  local T="$SANDBOX/.delegate/tasks"

  # First attempt hangs.
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-42 60 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/mockout/opencode.pid" || return 1
  local first_pid
  first_pid=$(cat "$T/TASK-42.pid")

  # A second launch while it runs must be refused — two agents, one worktree.
  local code=0
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-42 60 < /dev/null > "$SANDBOX/out2" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q "still running" "$SANDBOX/out2" || return 1

  # stop terminates it (the supervisor then records the exit code).
  bash "$DELEGATE_SH" stop TASK-42 | grep -q "^STATE=STOPPED$" || return 1
  kill -0 "$first_pid" 2>/dev/null && return 1
  [ -f "$T/TASK-42.exitcode" ] || return 1
  bash "$DELEGATE_SH" stop TASK-42 | grep -q "^STATE=NOT_RUNNING$" || return 1
  bash "$DELEGATE_SH" status TASK-42 | grep -q "^STATE=STOPPED$" || return 1

  # Self-healing bumps the counter, then relaunches with --continue.
  echo 1 > "$T/TASK-42.retries"
  rm -f "$SANDBOX/mockout/opencode.args"
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-42 60 --continue < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  [ "$(cat "$T/TASK-42.retries")" = 1 ] || return 1        # never reset
  [ -f "$T/TASK-42.log.prev" ] || return 1                  # old log kept
  [ "$(cat "$T/TASK-42.pid")" != "$first_pid" ] || return 1 # fresh PID recorded
  wait_for_mock_file "$SANDBOX/mockout/opencode.args" || return 1
  grep -qx -- "--continue" "$SANDBOX/mockout/opencode.args" || return 1
  wait_for_mock_file "$T/TASK-42.exitcode" || return 1
  [ "$(cat "$T/TASK-42.exitcode")" = 0 ] || return 1
  bash "$DELEGATE_SH" status TASK-42 | grep -q "^STATE=EXITED_OK$" || return 1
}

# ─── Test 18d: --continue / --model map to each runtime's real flags ────

test_continue_and_model_flags() {
  local rt="$1" SANDBOX args
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-43"
  cp "$FIXTURES/$rt" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/$rt"
  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_MIMO_HAS_FILE=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" "$rt" TASK-43 30 --continue --model test-model/v1 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/mockout/$rt.args" || return 1
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-43.exitcode" || return 1
  args="$SANDBOX/mockout/$rt.args"
  [ "$(cat "$SANDBOX/mockout/$rt.cwd")" = "$SANDBOX/.delegate/worktrees/TASK-43" ] || return 1
  grep -qx "test-model/v1" "$args" || return 1
  case "$rt" in
    opencode|mimo) grep -qx -- --continue "$args" && grep -qx -- -m "$args" ;;
    pi)            grep -qx -- --continue "$args" && grep -qx -- --model "$args" ;;
    hermes)        grep -qx -- --continue "$args" && grep -qx -- -m "$args" ;;
    agy)           grep -qx -- --continue "$args" && grep -qx -- --model "$args" ;;
    # kimi's continue flag is lowercase -c; -C does not exist.
    kimi)          grep -qx -- -c "$args" && ! grep -qx -- -C "$args" && grep -qx -- -m "$args" ;;
    # codex resume accepts neither -C nor -s; sandbox goes via -c config.
    codex)         grep -qx resume "$args" && grep -qx -- --last "$args" &&
                   ! grep -qx -- -C "$args" && ! grep -qx -- -s "$args" &&
                   grep -qx 'sandbox_mode="workspace-write"' "$args" &&
                   grep -q "Continue the task" "$SANDBOX/mockout/codex.stdin" ;;
  esac
}

# ─── Test 18e: invalid --model values are refused before launch ─────────

test_reject_bad_model() {
  local SANDBOX m code
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/bin"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-44"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"
  for m in '--auto' 'a b' 'x;touch escape' ''; do
    code=0
    PATH="$SANDBOX/bin:$PATH" bash "$DELEGATE_SH" opencode TASK-44 30 --model "$m" > "$SANDBOX/out" 2>&1 || code=$?
    [ "$code" = 1 ] || return 1
  done
  [ ! -f "$SANDBOX/escape" ] && [ ! -f "$SANDBOX/.delegate/tasks/TASK-44.supervisor.sh" ]
}

# ─── Test 18f: launch keeps .delegate/ out of the main tree's git status ─

test_delegate_dir_ignored() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-45"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-45 30 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-45.exitcode" || return 1
  [ -z "$(git -C "$SANDBOX" status --porcelain -- .delegate)" ] || return 1
  # Excluded through the never-committed info/exclude, not a tracked .gitignore.
  [ ! -f "$SANDBOX/.gitignore" ] || return 1
  # Idempotent: a second launch does not append the pattern again.
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-45 30 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  [ "$(grep -cx '.delegate/' "$SANDBOX/.git/info/exclude")" = 1 ] || return 1
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-45.exitcode"
}

# ─── Test 19: status NOT_FOUND for an unknown task ──────────────────────

test_status_not_found() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/.delegate/tasks"
  cd "$SANDBOX"
  bash "$DELEGATE_SH" status TASK-999 | grep -q "^STATE=NOT_FOUND$" || return 1
}

# ─── Test 20: verify runs the handoff's fenced verification block ────────

test_verify_pass_and_fail() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN

  mkdir -p "$SANDBOX/.delegate/tasks"
  cd "$SANDBOX"

  cat > "$SANDBOX/.delegate/tasks/TASK-20.md" <<'EOF'
# Handoff: TASK-20

## Verification Expectations
```bash
echo "checking"
exit 0
```
EOF
  # Captured via command substitution rather than piped straight into grep:
  # under pipefail (active in run-tests.sh), a pipeline's exit status is the
  # rightmost NONZERO stage — so `verify | grep -q ...` would report verify's
  # own designed-nonzero exit code even when grep matched successfully.
  local out20
  out20=$(bash "$DELEGATE_SH" verify TASK-20)
  echo "$out20" | grep -q "^STATE=PASS$" || return 1

  cat > "$SANDBOX/.delegate/tasks/TASK-21.md" <<'EOF'
# Handoff: TASK-21

## Verification Expectations
```bash
exit 7
```
EOF
  local out
  out=$(bash "$DELEGATE_SH" verify TASK-21)
  local code=$?
  echo "$out" | grep -q "^STATE=FAIL$" || return 1
  echo "$out" | grep -q "^EXITCODE=7$" || return 1
  [ "$code" = "7" ] || return 1

  # An early failing check must fail the whole block, even when the last
  # command succeeds (the block runs under errexit + pipefail).
  cat > "$SANDBOX/.delegate/tasks/TASK-23.md" <<'EOF'
# Handoff: TASK-23

## Verification Expectations
```bash
false
echo "last command succeeds"
```
EOF
  local out23 code23=0
  out23=$(bash "$DELEGATE_SH" verify TASK-23) || code23=$?
  echo "$out23" | grep -q "^STATE=FAIL$" || return 1
  [ "$code23" != 0 ] || return 1

  # A failing stage inside a pipeline is caught too (```sh fences accepted).
  cat > "$SANDBOX/.delegate/tasks/TASK-24.md" <<'EOF'
# Handoff: TASK-24

## Verification Expectations
```sh
(exit 5) | cat
```
EOF
  local out24
  out24=$(bash "$DELEGATE_SH" verify TASK-24) || true
  echo "$out24" | grep -q "^STATE=FAIL$" || return 1

  # No fenced block at all → NO_VERIFICATION_BLOCK, distinct from FAIL.
  cat > "$SANDBOX/.delegate/tasks/TASK-22.md" <<'EOF'
# Handoff: TASK-22

## Verification Expectations
Just check it manually.
EOF
  local out22
  out22=$(bash "$DELEGATE_SH" verify TASK-22 2>/dev/null)
  echo "$out22" | grep -q "^STATE=NO_VERIFICATION_BLOCK$" || return 1
}

# ─── Test 21: reconcile reports stale in_progress entries ────────────────

test_reconcile_stale() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/.delegate/tasks"
  cd "$SANDBOX"

  cat > "$SANDBOX/TODO.md" <<'EOF'
## [TASK-30] a completed one
- status: completed

## [TASK-31] an orphaned one, never launched
- status: in_progress

## [TASK-32] a live one
- status: in_progress
EOF

  # TASK-32 looks alive: give it a real, currently-running pid. Must be a
  # disposable child process, NOT $$ (this test's own shell) — cleanup_sandbox
  # unconditionally kills whatever pid every .pid file names, and using $$
  # here previously made it SIGKILL the test harness itself mid-test.
  sleep 100 &
  local live_pid=$!
  echo "$live_pid" > "$SANDBOX/.delegate/tasks/TASK-32.pid"

  local out
  out=$(bash "$DELEGATE_SH" reconcile)
  kill -KILL "$live_pid" 2>/dev/null || true
  echo "$out" | grep -q "STALE TASK-31" || return 1
  echo "$out" | grep -q "STALE TASK-32" && return 1
  echo "$out" | grep -q "TASK-30" && return 1
  return 0
}

# ─── Test 22: next-id survives a missing TODO-ARCHIVE.md ─────────────────
#
# Regression test: `grep -h pattern TODO.md TODO-ARCHIVE.md` exits nonzero
# when one of the files is missing even though it matched in the other; under
# pipefail a naive `|| LAST_N=""` catch silently discards a real match. This
# pinned the fix for that exact bug (found while first exercising `next-id`).

test_next_id_missing_archive() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  cd "$SANDBOX"

  # No TODO.md at all → starts at TASK-1.
  [ "$(bash "$DELEGATE_SH" next-id)" = "TASK-1" ] || return 1

  # TODO.md exists, TODO-ARCHIVE.md does not (the common case) → increments.
  cat > "$SANDBOX/TODO.md" <<'EOF'
## [TASK-1] foo
- status: completed
EOF
  [ ! -f "$SANDBOX/TODO-ARCHIVE.md" ] || return 1
  [ "$(bash "$DELEGATE_SH" next-id)" = "TASK-2" ] || return 1

  # Higher numbers live only in TODO-ARCHIVE.md → still takes the max.
  cat > "$SANDBOX/TODO-ARCHIVE.md" <<'EOF'
## [TASK-9] archived
- status: completed
EOF
  [ "$(bash "$DELEGATE_SH" next-id)" = "TASK-10" ] || return 1
}

# ─── Test 22b: next-id reserves what it hands out ────────────────────────
#
# The caller appends its TODO.md block only after next-id returns. Without a
# reservation, two callers in that window both computed the same id.

test_next_id_reserves() {
  local SANDBOX a b
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  cd "$SANDBOX"
  a=$(bash "$DELEGATE_SH" next-id) || return 1
  b=$(bash "$DELEGATE_SH" next-id) || return 1
  [ "$a" = TASK-1 ] && [ "$b" = TASK-2 ] || return 1
  [ -f "$SANDBOX/.delegate/tasks/TASK-1.reserved" ] || return 1
  # Parallel callers still get distinct ids.
  local i ids
  for i in 1 2 3 4 5; do bash "$DELEGATE_SH" next-id > "$SANDBOX/id.$i" & done
  wait
  ids=$(cat "$SANDBOX"/id.* | sort -u | wc -l | tr -d ' ')
  [ "$ids" = 5 ] || return 1
  # An existing handoff document counts as used even without a ledger block.
  create_handoff "$SANDBOX" TASK-20
  [ "$(bash "$DELEGATE_SH" next-id)" = TASK-21 ] || return 1
}

# ─── Test 23: timeout and stop reach the agent's descendants ─────────────
#
# The launched PID is often not the engine: an npm shim that does not exec, a
# CLI that spawns its worker, the agent's own shells and test runners. Without
# a process group (no setsid on Git Bash or stock macOS) only a recursive
# descendant kill reaches them. The fixture launches a wrapper whose GRANDCHILD
# is the hanging mock; the mock's own pid is what must die.

_descendant_fixture() {
  local sandbox="$1"
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  init_git_repo "$sandbox"
  cp "$FIXTURES/agy" "$sandbox/bin/agy-real"
  cat > "$sandbox/bin/agy" <<'EOF'
#!/bin/bash
# wrapper -> bash -c -> agy-real: the real agent is a grandchild, never exec'd
bash -c 'bash "$1" "${@:2}"' _ "$(dirname "$0")/agy-real" "$@"
EOF
  chmod +x "$sandbox/bin/agy" "$sandbox/bin/agy-real"
}

# Waits until the real mock recorded TERM (its trap writes KILLED) and its pid
# is gone. $1 = sandbox, $2 = real pid. Kills the leftover on failure so a
# failing test never leaks a hung process.
_wait_descendant_dead() {
  local sandbox="$1" real_pid="$2" waited=0
  while [ "$waited" -lt 100 ]; do
    snapshot_watchdog_children "$sandbox"
    grep -q KILLED "$sandbox/mockout/agy.status" 2>/dev/null && ! kill -0 "$real_pid" 2>/dev/null && return 0
    sleep 0.1; waited=$((waited + 1))
  done
  kill -KILL "$real_pid" 2>/dev/null
  return 1
}

test_timeout_kills_descendants() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  _descendant_fixture "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-50"
  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" agy TASK-50 2 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/mockout/agy.pid" || return 1
  local real_pid
  real_pid=$(cat "$SANDBOX/mockout/agy.pid")
  # Sanity: the recorded PID is the wrapper, not the engine.
  [ "$real_pid" != "$(cat "$SANDBOX/.delegate/tasks/TASK-50.pid")" ] || { kill -KILL "$real_pid"; return 1; }
  # The timer fires at 2s and must TERM the grandchild, not just the wrapper.
  _wait_descendant_dead "$SANDBOX" "$real_pid" || return 1
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-50.timedout" || return 1
  bash "$DELEGATE_SH" status TASK-50 | grep -q "^STATE=TIMED_OUT$"
}

test_stop_kills_descendants() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  _descendant_fixture "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-51"
  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" agy TASK-51 120 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/mockout/agy.pid" || return 1
  local real_pid
  real_pid=$(cat "$SANDBOX/mockout/agy.pid")
  bash "$DELEGATE_SH" stop TASK-51 | grep -q "^STATE=STOPPED$" || { kill -KILL "$real_pid"; return 1; }
  _wait_descendant_dead "$SANDBOX" "$real_pid" || return 1
  bash "$DELEGATE_SH" status TASK-51 | grep -q "^STATE=STOPPED$"
}

# ─── Test 24: stop/timeout markers classify without an exit code ─────────
#
# If the supervisor died (session teardown, killed watchdog) no .exitcode is
# written. A deliberately stopped or timed-out task must still not read as
# LAUNCH_FAILED, which Step 5 Case 1 would relaunch.

test_status_markers_without_exitcode() {
  local SANDBOX dead T
  SANDBOX=$(mktemp -d)
  T="$SANDBOX/.delegate/tasks"
  # Remove the .pid before cleanup: it names a reaped pid that cleanup must
  # not try to kill (a reused pid would belong to someone else).
  trap "rm -f '$T/TASK-52.pid'; cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$T"
  cd "$SANDBOX"
  true & dead=$!; wait "$dead" 2>/dev/null
  printf '# Handoff\n' > "$T/TASK-52.md"
  echo "$dead" > "$T/TASK-52.pid"
  echo short > "$T/TASK-52.log"
  : > "$T/TASK-52.stopped"
  local out
  out=$(bash "$DELEGATE_SH" status TASK-52)
  echo "$out" | grep -q "^STATE=STOPPED$" || return 1
  echo "$out" | grep -q "^EXITCODE=" && return 1
  rm "$T/TASK-52.stopped"
  : > "$T/TASK-52.timedout"
  bash "$DELEGATE_SH" status TASK-52 | grep -q "^STATE=TIMED_OUT$" || return 1
  # With an exit code the marker still wins and the code is reported.
  echo 143 > "$T/TASK-52.exitcode"
  out=$(bash "$DELEGATE_SH" status TASK-52)
  echo "$out" | grep -q "^STATE=TIMED_OUT$" && echo "$out" | grep -q "^EXITCODE=143$"
}

# ─── Test 25: relaunch after the worktree directory was deleted by hand ──

test_relaunch_after_worktree_deleted() {
  local SANDBOX
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  create_handoff "$SANDBOX" "TASK-53"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-53 30 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-53.exitcode" || return 1
  rm -rf "$SANDBOX/.delegate/worktrees/TASK-53"
  git -C "$SANDBOX" worktree list | grep -q prunable || return 1   # precondition
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-53 30 < /dev/null > "$SANDBOX/out2" 2>&1 || { cat "$SANDBOX/out2" >&2; return 1; }
  snapshot_watchdog_children "$SANDBOX"
  [ -d "$SANDBOX/.delegate/worktrees/TASK-53" ] || return 1
  [ "$(git -C "$SANDBOX/.delegate/worktrees/TASK-53" symbolic-ref --short HEAD)" = "opencode/TASK-53" ] || return 1
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-53.exitcode"
}

# ─── Test 26: status reports STALLED for a silent agent ──────────────────
#
# $1 = worktree | unisolated. The mock writes its heartbeat OUTSIDE the
# sandbox so the only "activity" the scan could see is agent work. In
# unisolated mode the work dir is the project root, where status's own
# .delegate bookkeeping used to count as activity (STALLED never fired).

test_status_stalled() {
  local mode="$1" SANDBOX OUT
  SANDBOX=$(mktemp -d)
  OUT=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'; rm -rf '$OUT'" RETURN
  mkdir -p "$SANDBOX/bin" "$SANDBOX/.delegate/tasks"
  local env_extra=()
  if [ "$mode" = worktree ]; then
    init_git_repo "$SANDBOX"
  else
    env_extra=(DELEGATE_ALLOW_UNISOLATED=1)
  fi
  create_handoff "$SANDBOX" "TASK-54"
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"
  env "${env_extra[@]}" PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$OUT" \
    bash "$DELEGATE_SH" opencode TASK-54 120 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$OUT/opencode.pid" || return 1
  local work="$SANDBOX/.delegate/worktrees/TASK-54"
  [ "$mode" = worktree ] || work="$SANDBOX"
  # First poll establishes the baseline; a second poll with no log growth and
  # no new files in the work dir is a stall; a new file in the work dir is not.
  bash "$DELEGATE_SH" status TASK-54 | grep -q "^STATE=RUNNING$" || { bash "$DELEGATE_SH" stop TASK-54 >/dev/null; return 1; }
  sleep 1.1
  bash "$DELEGATE_SH" status TASK-54 | grep -q "^STATE=STALLED$" || { bash "$DELEGATE_SH" stop TASK-54 >/dev/null; return 1; }
  sleep 1.1
  echo progress > "$work/progress.txt"
  bash "$DELEGATE_SH" status TASK-54 | grep -q "^STATE=RUNNING$" || { bash "$DELEGATE_SH" stop TASK-54 >/dev/null; return 1; }
  bash "$DELEGATE_SH" stop TASK-54 | grep -q "^STATE=STOPPED$"
}

# ─── Test 27: next-id reclaims a stale lock (portable mtime) ─────────────

test_next_id_reclaims_stale_lock() {
  local SANDBOX start id
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  cd "$SANDBOX"
  mkdir -p "$SANDBOX/.delegate/todo.lock"
  touch -t 200001010000 "$SANDBOX/.delegate/todo.lock" || return 1
  start=$(date +%s)
  id=$(bash "$DELEGATE_SH" next-id) || return 1
  [ "$id" = TASK-1 ] || return 1
  # Reclaimed immediately, not after the 10s give-up.
  [ $(( $(date +%s) - start )) -lt 8 ] || return 1
  [ ! -d "$SANDBOX/.delegate/todo.lock" ]
}

# ─── Test 28: cleanup — post-merge teardown ──────────────────────────────

test_cleanup() {
  local SANDBOX out wt="" code
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  mkdir -p "$SANDBOX/bin" "$SANDBOX/mockout"
  init_git_repo "$SANDBOX"
  local t
  for t in 55 56 58; do create_handoff "$SANDBOX" "TASK-$t"; done
  cp "$FIXTURES/opencode" "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/opencode"
  cd "$SANDBOX"

  # 1. Refuses while the agent is running, and removes nothing.
  PATH="$SANDBOX/bin:$PATH" MOCK_HANG=1 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-55 60 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/mockout/opencode.pid" || return 1
  code=0; bash "$DELEGATE_SH" cleanup TASK-55 > "$SANDBOX/out" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q "still running" "$SANDBOX/out" || { bash "$DELEGATE_SH" stop TASK-55 >/dev/null; return 1; }
  [ -d "$SANDBOX/.delegate/worktrees/TASK-55" ] || return 1
  bash "$DELEGATE_SH" stop TASK-55 | grep -q "^STATE=STOPPED$" || return 1

  # 2. Merged (no new commits) -> worktree and branch removed, logs kept.
  out=$(bash "$DELEGATE_SH" cleanup TASK-55) || return 1
  echo "$out" | grep -q "^STATE=CLEANED$" && echo "$out" | grep -q "^BRANCH=opencode/TASK-55$" || return 1
  [ ! -d "$SANDBOX/.delegate/worktrees/TASK-55" ] || return 1
  [ -z "$(git branch --list 'opencode/TASK-55')" ] || return 1
  [ -f "$SANDBOX/.delegate/tasks/TASK-55.log" ] || return 1
  bash "$DELEGATE_SH" cleanup TASK-55 | grep -q "^STATE=NOTHING_TO_CLEAN$" || return 1

  # 3. Unmerged commits -> refused with nothing removed; fine after the user merges.
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-56 60 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-56.exitcode" || return 1
  wt="$SANDBOX/.delegate/worktrees/TASK-56"
  git -C "$wt" commit -q --allow-empty -m "agent work" || return 1
  code=0; bash "$DELEGATE_SH" cleanup TASK-56 > "$SANDBOX/out" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q "not merged" "$SANDBOX/out" || return 1
  [ -d "$wt" ] && [ -n "$(git branch --list 'opencode/TASK-56')" ] || return 1
  git merge -q opencode/TASK-56 || return 1
  bash "$DELEGATE_SH" cleanup TASK-56 | grep -q "^STATE=CLEANED$" || return 1

  # 4. --force discards unmerged work and uncommitted changes.
  PATH="$SANDBOX/bin:$PATH" MOCK_DURATION=0 MOCK_OUT_DIR="$SANDBOX/mockout" \
    bash "$DELEGATE_SH" opencode TASK-58 60 < /dev/null > /dev/null 2>&1 || return 1
  snapshot_watchdog_children "$SANDBOX"
  wait_for_mock_file "$SANDBOX/.delegate/tasks/TASK-58.exitcode" || return 1
  wt="$SANDBOX/.delegate/worktrees/TASK-58"
  git -C "$wt" commit -q --allow-empty -m "unmerged" || return 1
  echo scratch > "$wt/untracked.txt"
  code=0; bash "$DELEGATE_SH" cleanup TASK-58 > /dev/null 2>&1 || code=$?
  [ "$code" = 1 ] || return 1
  bash "$DELEGATE_SH" cleanup TASK-58 --force | grep -q "^STATE=CLEANED$" || return 1
  [ ! -d "$wt" ] && [ -z "$(git branch --list 'opencode/TASK-58')" ]
}

# ─── Test 29: version, --help, and the workflow's launcher resolver ──────

test_version_and_resolver() {
  local SANDBOX v code skill_dir snippet
  SANDBOX=$(mktemp -d)
  trap "cleanup_sandbox '$SANDBOX'" RETURN
  cd "$SANDBOX"
  v=$(bash "$DELEGATE_SH" version) || return 1
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  code=0; bash "$DELEGATE_SH" --help > /dev/null 2>&1 || code=$?
  [ "$code" = 0 ] || return 1
  code=0; bash "$DELEGATE_SH" > /dev/null 2>&1 || code=$?
  [ "$code" = 1 ] || return 1

  # Run the workflow's own resolver snippet against fake skill/project layouts.
  skill_dir="$SANDBOX/skill"
  mkdir -p "$skill_dir/scripts" "$SANDBOX/proj/scripts"
  cp "$DELEGATE_SH" "$skill_dir/scripts/delegate.sh"
  snippet=$(awk '/^Resolve it once/{s=1} s&&/^```bash/{c=1;next} s&&c&&/^```/{exit} s&&c' "$PROJECT_ROOT/skills/shared/workflow.md" | sed "s|<skill-dir>|$skill_dir|g")
  [ -n "$snippet" ] || return 1
  cd "$SANDBOX/proj"
  resolve() { bash -c "$snippet" 2>"$SANDBOX/resolver.err" | sed -n 's/^DELEGATE_SH=//p'; }

  # no project copy -> bundled
  [ "$(resolve)" = "$skill_dir/scripts/delegate.sh" ] || return 1
  # pre-1.4 project copy (no `version` subcommand) -> bundled, with a warning
  printf '#!/usr/bin/env bash\nexit 1\n' > scripts/delegate.sh
  [ "$(resolve)" = "$skill_dir/scripts/delegate.sh" ] && grep -q "older than the bundled" "$SANDBOX/resolver.err" || return 1
  # same-version project copy -> the project's own copy wins
  cp "$DELEGATE_SH" scripts/delegate.sh
  [ "$(resolve)" = "scripts/delegate.sh" ] || return 1
  # newer project copy -> the project's own copy wins
  printf '#!/usr/bin/env bash\n[ "${1:-}" = version ] && echo 9.9.9\n' > scripts/delegate.sh
  [ "$(resolve)" = "scripts/delegate.sh" ] || return 1
  # project copy but no bundled one at all -> the project's copy
  rm -rf "$skill_dir/scripts"
  [ "$(resolve)" = "scripts/delegate.sh" ]
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
test_not_git_repo && pass "Not a git repo → explicitly opted-in project-root launch" || fail "Not a git repo → explicitly opted-in project-root launch"
test_worktree_reuse && pass "Worktree reuse — second launch for same TASK-N" || fail "Worktree reuse — second launch for same TASK-N"
test_watchdog_sigterm && pass "Watchdog SIGTERM fires on timeout" || fail "Watchdog SIGTERM fires on timeout"
test_exit_code_capture && pass "Real exit code captured; watchdog self-cancels on success" || fail "Real exit code captured; watchdog self-cancels on success"
test_status_failed_exitcode && pass "status reports TIMED_OUT with the real exit code" || fail "status reports TIMED_OUT with the real exit code"
test_status_not_found && pass "status reports NOT_FOUND for an unknown task" || fail "status reports NOT_FOUND for an unknown task"
test_verify_pass_and_fail && pass "verify runs the handoff's fenced verification block" || fail "verify runs the handoff's fenced verification block"
test_reconcile_stale && pass "reconcile reports stale in_progress entries only" || fail "reconcile reports stale in_progress entries only"
test_status_failure_classes && pass "status classifies EXITED_FAILED vs LAUNCH_FAILED by output size" || fail "status classifies EXITED_FAILED vs LAUNCH_FAILED by output size"
test_relaunch_semantics && pass "Relaunch keeps retries, rotates log, refuses while running; stop works" || fail "Relaunch keeps retries, rotates log, refuses while running; stop works"
for rt in opencode pi mimo hermes kimi codex agy; do
  test_continue_and_model_flags "$rt" && pass "$rt --continue/--model map to real CLI flags" || fail "$rt --continue/--model map to real CLI flags"
done
test_reject_bad_model && pass "Invalid --model values refused before launch" || fail "Invalid --model values refused before launch"
test_delegate_dir_ignored && pass ".delegate/ excluded from main-tree git status (idempotent)" || fail ".delegate/ excluded from main-tree git status (idempotent)"
test_next_id_reserves && pass "next-id reserves ids (sequential and parallel callers)" || fail "next-id reserves ids (sequential and parallel callers)"
test_next_id_missing_archive && pass "next-id survives a missing TODO-ARCHIVE.md (regression)" || fail "next-id survives a missing TODO-ARCHIVE.md (regression)"
test_timeout_kills_descendants && pass "Timeout kills the agent's grandchild (no process group needed)" || fail "Timeout kills the agent's grandchild (no process group needed)"
test_stop_kills_descendants && pass "stop kills the agent's grandchild (no process group needed)" || fail "stop kills the agent's grandchild (no process group needed)"
test_status_markers_without_exitcode && pass "status: STOPPED/TIMED_OUT markers win without an exit code" || fail "status: STOPPED/TIMED_OUT markers win without an exit code"
test_relaunch_after_worktree_deleted && pass "Relaunch after the worktree dir was deleted by hand (prune)" || fail "Relaunch after the worktree dir was deleted by hand (prune)"
for mode in worktree unisolated; do
  test_status_stalled "$mode" && pass "status reports STALLED for a silent agent ($mode)" || fail "status reports STALLED for a silent agent ($mode)"
done
test_cleanup && pass "cleanup: refuses while running / unmerged, removes worktree+branch, keeps logs" || fail "cleanup: refuses while running / unmerged, removes worktree+branch, keeps logs"
test_version_and_resolver && pass "version, --help exit codes, and the workflow launcher resolver prefer the newer copy" || fail "version, --help exit codes, and the workflow launcher resolver prefer the newer copy"
test_next_id_reclaims_stale_lock && pass "next-id reclaims a stale lock via portable mtime" || fail "next-id reclaims a stale lock via portable mtime"

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
