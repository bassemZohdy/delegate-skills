---
name: delegate-to-agy
description: Delegates coding tasks to Agy running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Agy for background execution.
license: MIT
compatibility: Requires git, bash, and agy on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.3.1
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Agy

Hands a coding task to Agy in the background with git worktree isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v agy &>/dev/null; then
  echo "agy"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — Agy does not expose a `--model` flag at the CLI level; model selection is configured in its settings. If the user requests a specific model, check Agy's config documentation — it cannot be passed via CLI.

**Flags** — Agy has no `--file` or `--dir` flag. The handoff document is referenced by absolute path in the prompt so the agent reads it via its own file tools. Agy supports `--add-dir` to add extra directories to its workspace — pass the worktree path this way. Agy runs from the current working directory; stay in the project root and use `--add-dir` for the worktree.

```bash
agy --help 2>&1 | grep -E "print|continue|skip-permissions|add-dir"
# --print / -p            → non-interactive single prompt (required for background)
# --continue / -c         → continue the most recent conversation
# --dangerously-skip-permissions → auto-approve all tool requests
# --add-dir               → add directory to workspace (repeat for multiple dirs)
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

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="$PROJECT_ROOT"
fi

TASK_FILE="$PROJECT_ROOT/.delegate/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>
UNSAFE_ARGS=()
[ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && UNSAFE_ARGS+=(--dangerously-skip-permissions)

nohup agy \
  --print "Read $TASK_FILE and execute the task described in it. All file changes must be made inside $WORK_DIR. Follow all instructions exactly." \
  --add-dir "$WORK_DIR" \
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
  "message": "'agy' not found on PATH.",
  "required": ["agy"],
  "resolution": "Install Agy and ensure it is on PATH, then retry /delegate-to-agy."
}
```

Tell the user: task ID, working directory (`$WORK_DIR`), timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (PROJECT_ROOT and WORK_DIR already set from launch):
```bash
nohup agy \
  --continue \
  --print "Continue the task from where you left off. Task file: $TASK_FILE" \
  --add-dir "$WORK_DIR" \
  ${UNSAFE_ARGS[@]+"${UNSAFE_ARGS[@]}"} \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
```
