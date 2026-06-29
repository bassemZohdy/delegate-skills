---
name: delegate-to-kimi
description: Delegates coding tasks to Kimi Code Agent running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Kimi for background execution.
disable-model-invocation: true
---

# Delegate to Kimi

Hands a coding task to Kimi Code in the background with full isolation, structured context, and ongoing review.

Follow the shared workflow in [`../docs/workflow.md`](../docs/workflow.md) for Steps 0–3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v kimi &>/dev/null; then
  echo "kimi"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `-m` if the user explicitly requested a model:
```bash
# Kimi model aliases are provider-specific; check kimi docs or config.toml for valid names.
# If invalid, kimi errors on start and self-healing Case 1 catches it.
# kimi -m "<requested-model>" ...
```
If no model was requested, omit `-m` entirely.

**Flags** — Kimi has no `--file` or `--dir` flag. The handoff document is referenced by absolute path in the prompt so the agent reads it via its own file tools. `cd` into the worktree before launching; capture `PROJECT_ROOT` first to keep log/pid paths correct.

```bash
kimi --help 2>&1 | grep -E "yolo|auto|continue|model"
# -y / --yolo  → auto-approve all actions (required for background runs)
# --auto       → start in auto permission mode
# -C / --continue → continue previous session for cwd
# -m / --model → model override
```

### Launch

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

# Add -m "<model>" only if user specified one
cd "$WORK_DIR" && nohup kimi \
  -p "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly." \
  -y \
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
  "message": "'kimi' not found on PATH.",
  "required": ["kimi"],
  "resolution": "Install Kimi Code CLI and ensure it is on PATH, then retry /delegate-to-kimi."
}
```

Tell the user: task ID, working directory (`$WORK_DIR`), timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (PROJECT_ROOT and WORK_DIR already set from launch):
```bash
cd "$WORK_DIR" && nohup kimi \
  -p "Continue the task from where you left off. Task file: $TASK_FILE" \
  -C -y \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
```
