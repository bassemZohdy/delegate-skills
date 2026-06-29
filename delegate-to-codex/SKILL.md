---
name: delegate-to-codex
description: Delegates coding tasks to OpenAI Codex CLI running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Codex for background execution.
disable-model-invocation: true
---

# Delegate to Codex

Hands a coding task to OpenAI Codex CLI in the background with full isolation, structured context, and ongoing review.

Follow the shared workflow in [`../docs/workflow.md`](../docs/workflow.md) for Steps 0–3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v codex &>/dev/null; then
  echo "codex"
else
  echo "none"
fi
```

### Validate Model and Flags

**Model** — only pass `-m` if the user explicitly requested a model. Codex uses OpenAI model names (e.g. `o3`, `o4-mini`, `gpt-4o`). No list command; pass directly.
```bash
# codex exec -m "<requested-model>" ...
# If invalid, codex errors on start and self-healing Case 1 catches it.
```
If no model was requested, omit `-m` entirely.

**Flags** — Codex supports stdin input via `-` positional argument: when `-` is passed, instructions are read from stdin. If both a positional prompt and `-` are given, stdin is appended as a `<stdin>` block. This is used instead of a `--file` flag. Use `-C/--cd` for working directory — no `cd` required.

```bash
codex exec --help 2>&1 | grep -E "\-\-cd|\-s sandbox|bypass-approvals|resume"
# -C / --cd DIR         → set working directory
# -s danger-full-access → allow all file system writes
# --dangerously-bypass-approvals-and-sandbox → skip all prompts (required for background)
# codex exec resume --last → resume most recent session
```

### Launch

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TASK_FILE=".opencode/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

# Add -m "<model>" only if user specified one
# Pipe handoff via stdin using '-'; codex reads the full file as instructions
export _CODEX_WORK_DIR="$WORK_DIR"
export _CODEX_TASK_FILE="$TASK_FILE"
nohup bash -c \
  'codex exec -C "$_CODEX_WORK_DIR" -s danger-full-access --dangerously-bypass-approvals-and-sandbox - < "$_CODEX_TASK_FILE"' \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"
unset _CODEX_WORK_DIR _CODEX_TASK_FILE

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

**`none` — abort:**
```json
{
  "error": "missing_runtime",
  "message": "'codex' not found on PATH.",
  "required": ["codex"],
  "resolution": "Install OpenAI Codex CLI and ensure it is on PATH, then retry /delegate-to-codex."
}
```

Tell the user: task ID, working directory (`$WORK_DIR`), timeout deadline.

### Retry (Step 5 Case 2)

When self-healing retries, resume the last session and append the handoff as additional context:
```bash
export _CODEX_WORK_DIR="$WORK_DIR"
export _CODEX_TASK_FILE="$TASK_FILE"
nohup bash -c \
  'codex exec resume --last -C "$_CODEX_WORK_DIR" -s danger-full-access --dangerously-bypass-approvals-and-sandbox' \
  > ".opencode/tasks/TASK-N.log" 2>&1 &
unset _CODEX_WORK_DIR _CODEX_TASK_FILE
```
