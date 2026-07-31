---
name: delegate-to-opencode
description: Delegates coding tasks to opencode (or oh-my-opencode) running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to opencode for background execution.
license: MIT
compatibility: Requires git, bash, and opencode or oh-my-opencode on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.3.1
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to OpenCode

Hands a coding task to opencode in the background with full isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

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

**Auto-approval flag** — required for unattended background runs. The flag name has changed across opencode versions (`--dangerously-skip-permissions` was replaced by `--auto` as of v1.17.x) — never hardcode one, detect it. Check the deprecated flag first so `--auto` wins when a version supports both:
```bash
OPENCODE_HELP=$(opencode run --help 2>&1)
OPENCODE_AUTO_FLAG=""
echo "$OPENCODE_HELP" | grep -q -- "--dangerously-skip-permissions" && OPENCODE_AUTO_FLAG="--dangerously-skip-permissions"
echo "$OPENCODE_HELP" | grep -q -- "--auto" && OPENCODE_AUTO_FLAG="--auto"
# If neither is present, omit the flag — the run may then block on interactive prompts.
```

### Launch

**Critical: never expand the handoff document into a shell variable.** Multi-line markdown with special characters (`#`, backticks, quotes, brackets) breaks positional argument parsing cross-platform. Instead, attach the handoff file with `--file` and pass a short prompt as the message.

**`opencode`:**
```bash
# Capture PROJECT_ROOT first — --dir points opencode's cwd at the worktree, so any
# relative path (e.g. --file) would otherwise resolve inside the worktree instead
# of the project root, where .delegate/tasks/ actually lives.
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TIMEOUT_SECS=<seconds from timeout tier>

nohup opencode run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  --file "$PROJECT_ROOT/.delegate/tasks/TASK-N.md" \
  --dir "$WORK_DIR" \
  $OPENCODE_AUTO_FLAG \
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

**`omo` — oh-my-opencode:**
```bash
# Capture PROJECT_ROOT first — both branches below either point omo's --dir at the
# worktree or cd into it, so any relative path (e.g. --file) must be made absolute
# against PROJECT_ROOT or it will fail to resolve once the cwd changes.
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TIMEOUT_SECS=<seconds from timeout tier>

# Help-check both flags — omo may support --file and/or --dir (varies by version).
# If --dir is unsupported, fall back to cd so the agent still runs in the worktree.
# Build args as an ARRAY — a flat string like "--file $PROJECT_ROOT/..." word-splits
# on spaces in the path. ${arr[@]+...} keeps an empty array safe under `set -u`.
OMO_HELP=$(oh-my-opencode run --help 2>&1)
OMO_ARGS=() ; OMO_HAS_DIR=""
echo "$OMO_HELP" | grep -q "\-\-file" && OMO_ARGS+=(--file "$PROJECT_ROOT/.delegate/tasks/TASK-N.md")
echo "$OMO_HELP" | grep -q "\-\-dir" && { OMO_HAS_DIR=1; OMO_ARGS+=(--dir "$WORK_DIR"); }

if [ -n "$OMO_HAS_DIR" ]; then
  # --dir supported: pass it directly (no cd needed)
  nohup oh-my-opencode run \
    "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
    ${OMO_ARGS[@]+"${OMO_ARGS[@]}"} \
    --yes \
    > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
else
  # No --dir flag: cd into the worktree so isolation still holds.
  cd "$WORK_DIR" && nohup oh-my-opencode run \
    "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
    ${OMO_ARGS[@]+"${OMO_ARGS[@]}"} \
    --yes \
    > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
fi

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
  "message": "Neither 'oh-my-opencode' nor 'opencode' found on PATH.",
  "required": ["oh-my-opencode", "opencode"],
  "resolution": "Install one and ensure it is on PATH, then retry /delegate-to-opencode."
}
```

Tell the user: task ID, which binary launched, working directory, timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries with `--continue` (reuse `$PROJECT_ROOT`, `$WORK_DIR`, and `$OPENCODE_AUTO_FLAG` from the initial launch):
```bash
nohup opencode run \
  "Continue the task from where you left off." \
  --file "$PROJECT_ROOT/.delegate/tasks/TASK-N.md" \
  --dir "$WORK_DIR" \
  --continue \
  $OPENCODE_AUTO_FLAG \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
```
