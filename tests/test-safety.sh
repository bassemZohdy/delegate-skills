#!/usr/bin/env bash
# Mock-only safety regressions. Sourced after test-behavior.sh for sandbox helpers.

test_runtime_permissions() {
  local runtime="$1" mode="$2" sandbox args flag
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-60
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  cp "$FIXTURES/$runtime" "$sandbox/bin/"
  chmod +x "$sandbox/bin/$runtime"
  PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNSAFE_FLAGS="$mode" DELEGATE_ALLOW_UNISOLATED=0 \
    MOCK_DURATION=0 MOCK_MIMO_HAS_FILE=1 MOCK_OUT_DIR="$sandbox/mockout" \
    bash "$DELEGATE_SH" "$runtime" TASK-60 30 > "$sandbox/output" 2>&1 || return 1
  snapshot_watchdog_children "$sandbox"
  wait_for_mock_file "$sandbox/mockout/$runtime.args" || return 1
  args="$sandbox/mockout/$runtime.args"
  if [ "$mode" = 0 ]; then
    if grep -Eq -- '^--(auto|approve|yolo|accept-hooks|dangerously-.*)$|^-y$|^danger-full-access$' "$args"; then
      cat "$args" >&2
      return 1
    fi
    [ "$runtime" != codex ] || grep -A1 -- '^-s$' "$args" | grep -qx 'workspace-write' || return 1
  else
    case "$runtime" in
      opencode) flag=--auto ;; pi) flag=--approve ;;
      mimo|agy) flag=--dangerously-skip-permissions ;;
      hermes) flag=--yolo ;; kimi) flag=-y ;;
      codex) flag=--dangerously-bypass-approvals-and-sandbox ;;
    esac
    grep -qx -- "$flag" "$args" || return 1
    [ "$runtime" != hermes ] || grep -qx -- '--accept-hooks' "$args" || return 1
    grep -q 'WARN: DELEGATE_ALLOW_UNSAFE_FLAGS=1' "$sandbox/output" || return 1
  fi
  # Working-directory flags are not a substitute for process cwd containment.
  [ "$(cat "$sandbox/mockout/$runtime.cwd")" = "$sandbox/.delegate/worktrees/TASK-60" ] || return 1
  wait_for_mock_file "$sandbox/.delegate/tasks/TASK-60.exitcode" || return 1
  [ "$(cat "$sandbox/.delegate/tasks/TASK-60.exitcode")" = 0 ] || return 1
}

test_worktree_failure() {
  local mode="$1" sandbox real_git
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-61
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  real_git=$(command -v git)
  # Force both real creation attempts to fail while preserving repository queries.
  cat > "$sandbox/bin/git" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != worktree ] || exit 1
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$sandbox/bin/"*
  local code=0
  REAL_GIT="$real_git" PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNISOLATED="$mode" \
    DELEGATE_ALLOW_UNSAFE_FLAGS=0 MOCK_DURATION=0 MOCK_OUT_DIR="$sandbox/mockout" \
    bash "$DELEGATE_SH" opencode TASK-61 30 > "$sandbox/output" 2>&1 || code=$?
  if [ "$mode" = 0 ]; then
    [ "$code" = 1 ] || return 1
    grep -q 'worktree creation failed.*refusing' "$sandbox/output" || return 1
    [ ! -f "$sandbox/mockout/opencode.args" ] && [ ! -f "$sandbox/.delegate/tasks/TASK-61.supervisor.sh" ] || return 1
  else
    [ "$code" = 0 ] || return 1
    snapshot_watchdog_children "$sandbox"
    grep -q 'WARN: DELEGATE_ALLOW_UNISOLATED=1' "$sandbox/output" || return 1
    wait_for_mock_file "$sandbox/mockout/opencode.cwd" || return 1
    [ "$(cat "$sandbox/mockout/opencode.cwd")" = "$sandbox" ] || return 1
    grep -qx -- --auto "$sandbox/mockout/opencode.args" && return 1
    wait_for_mock_file "$sandbox/.delegate/tasks/TASK-61.exitcode" || return 1
  fi
}

test_non_git_refused() {
  local sandbox code=0
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  cd "$sandbox"
  create_handoff "$sandbox" TASK-62
  mkdir -p "$sandbox/bin"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  chmod +x "$sandbox/bin/opencode"
  PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNISOLATED=0 DELEGATE_ALLOW_UNSAFE_FLAGS=0 \
    bash "$DELEGATE_SH" opencode TASK-62 30 > "$sandbox/output" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q 'not a git repo.*refusing' "$sandbox/output" &&
    [ ! -f "$sandbox/.delegate/tasks/TASK-62.supervisor.sh" ]
}

test_reject_bad_inputs() {
  local sandbox id code timeout
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-63
  mkdir -p "$sandbox/bin"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  chmod +x "$sandbox/bin/opencode"
  for id in ../escape TASK-0 TASK-01 TASK-1/../../escape 'TASK-1;touch escape'; do
    for command in opencode status verify; do
      code=0
      PATH="$sandbox/bin:$PATH" bash "$DELEGATE_SH" "$command" "$id" 30 > "$sandbox/output" 2>&1 || code=$?
      [ "$code" = 1 ] && grep -q 'task-id must be TASK-N' "$sandbox/output" || return 1
    done
  done
  for timeout in 0 -1 1.5 '1;touch escape'; do
    code=0
    PATH="$sandbox/bin:$PATH" bash "$DELEGATE_SH" opencode TASK-63 "$timeout" > "$sandbox/output" 2>&1 || code=$?
    [ "$code" = 1 ] && grep -q 'timeout-secs must be' "$sandbox/output" || return 1
  done
  for variable in DELEGATE_ALLOW_UNISOLATED DELEGATE_ALLOW_UNSAFE_FLAGS; do
    code=0
    env "$variable=true" PATH="$sandbox/bin:$PATH" bash "$DELEGATE_SH" opencode TASK-63 30 > "$sandbox/output" 2>&1 || code=$?
    [ "$code" = 1 ] && grep -q 'must be 0 or 1' "$sandbox/output" || return 1
  done
  [ ! -f "$sandbox/escape" ] && [ ! -f "$sandbox/.delegate/tasks/TASK-63.supervisor.sh" ]
}

test_reject_false_worktree() {
  local type="$1" sandbox code=0
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-64
  mkdir -p "$sandbox/bin" "$sandbox/.delegate/worktrees/TASK-64"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  chmod +x "$sandbox/bin/opencode"
  if [ "$type" = wrong-branch ]; then
    rmdir "$sandbox/.delegate/worktrees/TASK-64"
    git worktree add -q "$sandbox/.delegate/worktrees/TASK-64" -b unrelated-branch || return 1
  elif [ "$type" = foreign ]; then
    init_git_repo "$sandbox/.delegate/worktrees/TASK-64"
    cd "$sandbox"
  fi
  PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNISOLATED=1 \
    bash "$DELEGATE_SH" opencode TASK-64 30 > "$sandbox/output" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q 'existing worktree must belong' "$sandbox/output" &&
    [ ! -f "$sandbox/.delegate/tasks/TASK-64.supervisor.sh" ]
}

test_reject_symlink_path() {
  local kind="$1" sandbox target link code=0
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-65
  mkdir -p "$sandbox/bin" "$sandbox/outside" "$sandbox/.delegate/worktrees"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  chmod +x "$sandbox/bin/opencode"
  echo sentinel > "$sandbox/outside/sentinel"
  target="$sandbox/outside"
  case "$kind" in
    directory) link="$sandbox/.delegate/worktrees"; rmdir "$link" ;;
    worktree) link="$sandbox/.delegate/worktrees/TASK-65" ;;
    handoff) link="$sandbox/.delegate/tasks/TASK-65.md"; rm "$link"; target="$target/sentinel" ;;
    logfile) link="$sandbox/.delegate/tasks/TASK-65.log"; target="$target/sentinel" ;;
  esac
  # Native symlinks may be unavailable on a Windows host without developer mode.
  ln -s "$target" "$link" 2>/dev/null || return 2
  [ -L "$link" ] || return 2
  PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNISOLATED=1 \
    bash "$DELEGATE_SH" opencode TASK-65 30 > "$sandbox/output" 2>&1 || code=$?
  [ "$code" = 1 ] && grep -q 'ERROR:' "$sandbox/output" &&
    [ "$(cat "$sandbox/outside/sentinel")" = sentinel ] &&
    [ ! -f "$sandbox/.delegate/tasks/TASK-65.supervisor.sh" ]
}

test_legacy_opencode_optin() {
  local sandbox mode
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-66
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  cp "$FIXTURES/opencode" "$sandbox/bin/"
  chmod +x "$sandbox/bin/opencode"
  for mode in 0 1; do
    MOCK_OPENCODE_LEGACY=1 PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNSAFE_FLAGS="$mode" \
      MOCK_DURATION=0 MOCK_OUT_DIR="$sandbox/mockout" \
      bash "$DELEGATE_SH" opencode TASK-66 30 > "$sandbox/output" 2>&1 || return 1
    snapshot_watchdog_children "$sandbox"
    wait_for_mock_file "$sandbox/.delegate/tasks/TASK-66.exitcode" || return 1
    if [ "$mode" = 0 ]; then
      grep -qx -- --dangerously-skip-permissions "$sandbox/mockout/opencode.args" && return 1
    else
      grep -qx -- --dangerously-skip-permissions "$sandbox/mockout/opencode.args" || return 1
    fi
    rm "$sandbox/.delegate/tasks/TASK-66.exitcode"
  done
}

test_mimo_file_without_dir() {
  local sandbox
  sandbox=$(mktemp -d)
  trap "cleanup_sandbox '$sandbox'" RETURN
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-67
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  cp "$FIXTURES/mimo" "$sandbox/bin/"
  chmod +x "$sandbox/bin/mimo"
  MOCK_MIMO_HAS_FILE=1 MOCK_MIMO_HAS_DIR=0 PATH="$sandbox/bin:$PATH" \
    DELEGATE_ALLOW_UNSAFE_FLAGS=0 MOCK_DURATION=0 MOCK_OUT_DIR="$sandbox/mockout" \
    bash "$DELEGATE_SH" mimo TASK-67 30 > "$sandbox/output" 2>&1 || return 1
  snapshot_watchdog_children "$sandbox"
  wait_for_mock_file "$sandbox/mockout/mimo.cwd" || return 1
  [ "$(cat "$sandbox/mockout/mimo.cwd")" = "$sandbox/.delegate/worktrees/TASK-67" ] || return 1
  grep -qx -- --file "$sandbox/mockout/mimo.args" || return 1
  grep -qx -- --dir "$sandbox/mockout/mimo.args" && return 1
  wait_for_mock_file "$sandbox/.delegate/tasks/TASK-67.exitcode"
}

test_project_path_with_spaces() {
  local fixture sandbox
  fixture=$(mktemp -d)
  trap "cleanup_sandbox '$fixture'" RETURN
  sandbox="$fixture/project with spaces"
  mkdir -p "$sandbox"
  init_git_repo "$sandbox"
  create_handoff "$sandbox" TASK-68
  mkdir -p "$sandbox/bin" "$sandbox/mockout"
  cp "$FIXTURES/codex" "$sandbox/bin/"
  chmod +x "$sandbox/bin/codex"
  PATH="$sandbox/bin:$PATH" DELEGATE_ALLOW_UNSAFE_FLAGS=0 MOCK_DURATION=0 MOCK_OUT_DIR="$sandbox/mockout" \
    bash "$DELEGATE_SH" codex TASK-68 30 > "$sandbox/output" 2>&1 || return 1
  snapshot_watchdog_children "$sandbox"
  wait_for_mock_file "$sandbox/.delegate/tasks/TASK-68.exitcode" || return 1
  [ "$(cat "$sandbox/.delegate/tasks/TASK-68.exitcode")" = 0 ] || return 1
  grep -qx -- "$sandbox/.delegate/worktrees/TASK-68" "$sandbox/mockout/codex.args" || return 1
  grep -q 'This is a test handoff document for TASK-68' "$sandbox/mockout/codex.stdin"
}

for runtime in opencode pi mimo hermes kimi codex agy; do
  for mode in 0 1; do
    test_runtime_permissions "$runtime" "$mode" && pass "$runtime permission flags (opt-in=$mode)" || fail "$runtime permission flags (opt-in=$mode)"
  done
done
for mode in 0 1; do
  test_worktree_failure "$mode" && pass "Forced worktree failure (root opt-in=$mode)" || fail "Forced worktree failure (root opt-in=$mode)"
done
test_non_git_refused && pass "Non-git default refuses launch" || fail "Non-git default refuses launch"
test_reject_bad_inputs && pass "Task IDs, timeouts and opt-in values validated" || fail "Task IDs, timeouts and opt-in values validated"
for type in plain foreign wrong-branch; do
  test_reject_false_worktree "$type" && pass "Reject $type directory as a worktree" || fail "Reject $type directory as a worktree"
done
for kind in directory worktree handoff logfile; do
  code=0
  test_reject_symlink_path "$kind" || code=$?
  case "$code" in
    0) pass "Reject symlinked $kind path without modifying target" ;;
    2) case "$(uname -s)" in
         MINGW*|MSYS*|CYGWIN*) echo "  SKIP: native symlinks unavailable ($kind); Ubuntu CI must cover this" ;;
         *) fail "Native symlink fixture could not be created ($kind)" ;;
       esac ;;
    *) fail "Reject symlinked $kind path without modifying target" ;;
  esac
done
test_legacy_opencode_optin && pass "Legacy OpenCode approval bypass is opt-in only" || fail "Legacy OpenCode approval bypass is opt-in only"
test_mimo_file_without_dir && pass "MiMo file support without --dir enters verified worktree" || fail "MiMo file support without --dir enters verified worktree"
test_project_path_with_spaces && pass "Quoted project/handoff paths with spaces work" || fail "Quoted project/handoff paths with spaces work"
cd "$PROJECT_ROOT"
bash "$PROJECT_ROOT/helpers/scripts/sync-skills.sh" --check && pass "Canonical/mirrored skill distributions match" || fail "Canonical/mirrored skill distributions match"
