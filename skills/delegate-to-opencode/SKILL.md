---
name: delegate-to-opencode
description: Delegates coding tasks to opencode (or oh-my-opencode) running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to opencode for background execution.
license: MIT
compatibility: Requires git, bash, and opencode or oh-my-opencode on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.0.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to OpenCode

Hands a coding task to opencode in the background with full isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`../shared/workflow.md`](../shared/workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v oh-my-opencode &>/dev/null; then
  echo "omo"
elif command -v opencode &>/dev/null; then
  echo "opencode"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `-m` if the user explicitly requested a model. If they did, verify the exact ID:
```bash
opencode models 2>&1 | grep -i "<requested-model>"
# Use the full ID from that output. If nothing matches, tell the user and abort.
```
If no model was requested, omit `-m` entirely — opencode uses its configured default.

**Flags** — check what the runtime actually supports:
```bash
opencode run --help 2>&1 | grep -E "variant|effort"
# 'variant' present → may pass --variant <level> if appropriate
# 'effort' not present → never use it
```

### Launch

**Critical: never expand the handoff document into a shell variable.** Multi-line markdown with special characters (`#`, backticks, quotes, brackets) breaks positional argument parsing cross-platform. Instead, attach the handoff file with `--file` and pass a short prompt as the message.

**`opencode`:**
```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TIMEOUT_SECS=<seconds from timeout tier>

nohup opencode run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  --file ".opencode/tasks/TASK-N.md" \
  --dir "$WORK_DIR" \
  --dangerously-skip-permissions \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

**`omo` — oh-my-opencode:**
```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TIMEOUT_SECS=<seconds from timeout tier>

OMO_FILE_FLAG=""
oh-my-opencode run --help 2>&1 | grep -q "\-\-file" && OMO_FILE_FLAG="--file .opencode/tasks/TASK-N.md"

nohup oh-my-opencode run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  $OMO_FILE_FLAG \
  --yes \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

**`none` — abort:**
```json
{
  "error": "missing_runtime",
  "message": "Neither 'oh-my-opencode' nor 'opencode' found on PATH.",
  "required": ["oh-my-opencode", "opencode"],
  "resolution": "Install one and ensure it is on PATH, then retry /delegate-to-opencode."
}
```

Tell the user: task ID, which binary launched, working directory, timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue`:
```bash
nohup opencode run \
  "Continue the task from where you left off." \
  --file ".opencode/tasks/TASK-N.md" \
  --dir "$WORK_DIR" \
  --continue \
  --dangerously-skip-permissions \
  > ".opencode/tasks/TASK-N.log" 2>&1 &
```
