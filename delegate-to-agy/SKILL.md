---
name: delegate-to-agy
description: Delegates coding tasks to Agy running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Agy for background execution.
disable-model-invocation: true
---

# Delegate to Agy

Hands a coding task to Agy in the background with full isolation, structured context, and ongoing review.

Follow the shared workflow in [`../docs/workflow.md`](../docs/workflow.md) for Steps 0–3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

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

### Launch

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

nohup agy \
  --print "Read $TASK_FILE and execute the task described in it. All file changes must be made inside $WORK_DIR. Follow all instructions exactly." \
  --add-dir "$WORK_DIR" \
  --dangerously-skip-permissions \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
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
  --dangerously-skip-permissions \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
```
