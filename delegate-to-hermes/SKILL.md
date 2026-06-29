---
name: delegate-to-hermes
description: Delegates coding tasks to Hermes Agent running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Hermes for background execution.
disable-model-invocation: true
---

# Delegate to Hermes

Hands a coding task to Hermes in the background with full isolation, structured context, and ongoing review.

Follow the shared workflow in [`../docs/workflow.md`](../docs/workflow.md) for Steps 0–3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v hermes &>/dev/null; then
  echo "hermes"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `-m` if the user explicitly requested a model. Hermes does not expose a simple model list command; verify by checking the hermes documentation or your config. If the model name is wrong, hermes will error on launch and the self-healing Case 1 will catch it.
```bash
# Only if user specified a model — no machine-verifiable list; pass directly
# hermes chat -m "<requested-model>" ...
```
If no model was requested, omit `-m` entirely.

**Flags** — Hermes has no `--file` flag for general file attachment. The handoff document is passed as an absolute file path inside the query so the agent reads it using its own file tools. Hermes also has no `--dir` flag; `cd` into the worktree before launching and capture `PROJECT_ROOT` first to keep log/pid paths correct.

```bash
hermes chat --help 2>&1 | grep -E "worktree|accept-hooks|quiet|yolo"
# --worktree  → built-in worktree isolation (we manage our own; do NOT pass this)
# --accept-hooks → auto-approve hooks
# --yolo     → auto-approve all actions
# -Q / --quiet → suppress interactive output (required for background runs)
```

### Launch

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

# Add -m "<model>" only if user specified one and it was verified above
cd "$WORK_DIR" && nohup hermes chat \
  -q "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly." \
  --yolo --accept-hooks -Q \
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
  "message": "'hermes' not found on PATH.",
  "required": ["hermes"],
  "resolution": "Install Hermes Agent and ensure it is on PATH, then retry /delegate-to-hermes."
}
```

Tell the user: task ID, working directory (`$WORK_DIR`), timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (PROJECT_ROOT and WORK_DIR already set from launch):
```bash
cd "$WORK_DIR" && nohup hermes chat \
  -q "Continue the task from where you left off. Task file: $TASK_FILE" \
  --continue --yolo --accept-hooks -Q \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
```
