---
name: delegate-to-pi
description: Delegates coding tasks to pi (oh-my-pi / omp) running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to pi for background execution.
license: MIT
compatibility: Requires git, bash, and pi on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.3.1
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Pi

Hands a coding task to pi in the background with git worktree isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v pi &>/dev/null; then
  echo "pi"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `--model` if the user explicitly requested a model. If they did, verify the exact ID:
```bash
pi --list-models 2>&1 | grep -i "<requested-model>"
# Use the full ID from that output. If nothing matches, tell the user and abort.
```
If no model was requested, omit `--model` entirely — pi uses its configured default.

**Flags** — check what the runtime actually supports:
```bash
pi --help 2>&1 | grep -E "variant|thinking"
# 'variant' present → may pass --variant <level> if appropriate
# 'thinking' present → may pass --thinking <level> if appropriate
```

### Safety defaults

Prefer the tested launcher (`scripts/delegate.sh` when installed in the project).
For a manual launch, first verify a positive `TASK-N` identifier, real delegation
directories/state files without symlinks, and that the worktree belongs to this
repository and the expected runtime/task branch. Refuse an unrelated directory.

Preserve the runtime's permission settings and omit bypass flags by default.
This skill does not supply an OS sandbox or approvals a runtime lacks.
Git worktrees separate code edits; they
do not sandbox processes, network access, credentials or other host files.
Do not automatically enable approval-bypass flags to recover a stalled run.
Use `DELEGATE_ALLOW_UNSAFE_FLAGS=1` only after explicit operator opt-in for this
launch; otherwise omit all auto-approval, YOLO and sandbox-bypass flags. Safe
background runs may refuse operations or wait for approvals: report that outcome.
Never silently fall back to the project root. If isolation fails, stop unless
the operator explicitly set `DELEGATE_ALLOW_UNISOLATED=1` for this launch.

### Launch

**Critical: use `@` file references for the handoff document.** Pi reads file contents from `@path` positional arguments — never expand the handoff markdown into a shell variable.

**Note:** Pi has no `--dir` flag — `cd` into the worktree before launching. Capture `PROJECT_ROOT` *before* the `cd` so all `.delegate/tasks/` paths stay absolute and resolve correctly from the project root, not from inside the worktree.

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="$PROJECT_ROOT"
fi

TIMEOUT_SECS=<seconds from timeout tier>
UNSAFE_ARGS=()
[ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && UNSAFE_ARGS+=(--approve)

cd "$WORK_DIR" || exit 1
nohup pi -p \
  "@$PROJECT_ROOT/.delegate/tasks/TASK-N.md" \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  ${UNSAFE_ARGS[@]+"${UNSAFE_ARGS[@]}"} \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.delegate/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.delegate/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace. nohup'd (via a
# positional-arg bash -c, to dodge quoting issues) so it survives the calling
# terminal/session closing — a bare backgrounded subshell is not guaranteed to.
nohup bash -c 'sleep "$1"; kill -TERM "$2" 2>/dev/null; sleep 30; kill -KILL "$2" 2>/dev/null' \
  _ "$TIMEOUT_SECS" "$TASK_PID" > /dev/null 2>&1 &
echo $! > "$PROJECT_ROOT/.delegate/tasks/TASK-N.watchdog.pid"
```

**`none` — abort:**
```json
{
  "error": "missing_runtime",
  "message": "'pi' not found on PATH.",
  "required": ["pi"],
  "resolution": "Install pi and ensure it is on PATH, then retry /delegate-to-pi."
}
```

Tell the user: task ID, working directory, timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (PROJECT_ROOT and WORK_DIR already set from initial launch):
```bash
cd "$WORK_DIR" || exit 1
nohup pi -p \
  "@$PROJECT_ROOT/.delegate/tasks/TASK-N.md" \
  "Continue the task from where you left off." \
  --continue ${UNSAFE_ARGS[@]+"${UNSAFE_ARGS[@]}"} \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
```
