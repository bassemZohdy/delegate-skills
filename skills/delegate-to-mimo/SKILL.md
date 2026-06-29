---
name: delegate-to-mimo
description: Delegates coding tasks to mimo (MiMo Code Agent) running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to mimo for background execution.
license: MIT
compatibility: Requires git, bash, and mimo on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.0.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to MiMo

Hands a coding task to mimo in the background with full isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`../shared/workflow.md`](../shared/workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v mimo &>/dev/null; then
  echo "mimo"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `-m` if the user explicitly requested a model. If they did, verify the exact ID:
```bash
mimo models 2>&1 | grep -i "<requested-model>"
# Use the full ID from that output. If nothing matches, tell the user and abort.
```
If no model was requested, omit `-m` entirely — mimo uses its configured default.

**Flags** — check what the runtime actually supports before using any optional flags:
```bash
MIMO_HELP=$(mimo run --help 2>&1)
echo "$MIMO_HELP" | grep -E "variant|thinking"
# 'variant' present → may pass --variant <level> if appropriate
# 'thinking' present → may pass --thinking <level> if appropriate

# Also verify these flags exist — mimo may differ from opencode:
MIMO_HAS_DIR=$(echo "$MIMO_HELP" | grep -c "\-\-dir" || true)
MIMO_HAS_SKIP=$(echo "$MIMO_HELP" | grep -c "skip-permissions" || true)
MIMO_HAS_FILE=$(echo "$MIMO_HELP" | grep -c "\-\-file" || true)
```

Build the launch command from only the flags that are confirmed present. If `--file` is absent, fall back to attaching the handoff path as a positional argument (`@path` or similar — check help output).

### Launch

**Critical: never expand the handoff document into a shell variable.** Multi-line markdown with special characters (`#`, backticks, quotes, brackets) breaks positional argument parsing cross-platform. Attach the handoff file with `--file` and pass a short prompt as the message.

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TIMEOUT_SECS=<seconds from timeout tier>

# Build flags from confirmed support (checked above)
MIMO_DIR_FLAG=""
[ "$MIMO_HAS_DIR" -gt 0 ] && MIMO_DIR_FLAG="--dir $WORK_DIR"

MIMO_SKIP_FLAG=""
[ "$MIMO_HAS_SKIP" -gt 0 ] && MIMO_SKIP_FLAG="--dangerously-skip-permissions"

MIMO_FILE_FLAG=""
[ "$MIMO_HAS_FILE" -gt 0 ] && MIMO_FILE_FLAG="--file .opencode/tasks/TASK-N.md"

nohup mimo run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  $MIMO_FILE_FLAG \
  $MIMO_DIR_FLAG \
  $MIMO_SKIP_FLAG \
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
  "message": "'mimo' not found on PATH.",
  "required": ["mimo"],
  "resolution": "Install mimo and ensure it is on PATH, then retry /delegate-to-mimo."
}
```

Tell the user: task ID, working directory, timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (reuse `$MIMO_*_FLAG` variables from launch):
```bash
nohup mimo run \
  "Continue the task from where you left off." \
  $MIMO_FILE_FLAG \
  $MIMO_DIR_FLAG \
  --continue \
  $MIMO_SKIP_FLAG \
  > ".opencode/tasks/TASK-N.log" 2>&1 &
```
