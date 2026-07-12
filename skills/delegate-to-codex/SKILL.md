---
name: delegate-to-codex
description: Delegates coding tasks to OpenAI Codex CLI running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Codex for background execution.
license: MIT
compatibility: Requires git, bash, and codex on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.2.4
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Codex

Hands a coding task to OpenAI Codex CLI in the background with full isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`../shared/workflow.md`](../shared/workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

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

**Critical: pipe a framing instruction followed by the handoff via stdin.** Codex `exec ... -` reads stdin as the instruction set. Sending the raw handoff with no framing risks Codex treating the markdown as content to discuss rather than a task to execute. Prepend a one-line directive so the role of the handoff is unambiguous.

**Critical: codex must be the last element of the backgrounded pipeline.** `$!` is the PID of the last pipeline command — putting codex last makes the watchdog and liveness checks target codex itself. (Wrapping the whole pipeline in a backgrounded `bash -c` string captures the wrapper shell's PID instead; SIGTERM to that shell does not propagate to the piped codex child, so timeouts leave codex running.)

```bash
WORK_DIR=".delegate/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TASK_FILE=".delegate/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

# Add -m "<model>" only if user specified one.
{ printf '%s\n\n' "Execute the task described in the handoff document below. Follow all instructions in it exactly."; \
  cat "$TASK_FILE"; } | \
  nohup codex exec -C "$WORK_DIR" \
    -s danger-full-access \
    --dangerously-bypass-approvals-and-sandbox \
    - \
    > ".delegate/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".delegate/tasks/TASK-N.pid"
echo 0 > ".delegate/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".delegate/tasks/TASK-N.watchdog.pid"
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

When self-healing retries, resume the last session **with a continuation prompt**. `codex exec resume --last` needs an instruction to act on; an empty invocation will idle or exit. Pipe a short directive (with the handoff path for reference) via stdin — codex again last in the pipeline so `$!` is its PID:
```bash
printf '%s\n\n' "Continue the task from where you left off. The original task handoff is at: $TASK_FILE — re-read it if you need full context." | \
  nohup codex exec resume --last -C "$WORK_DIR" \
    -s danger-full-access \
    --dangerously-bypass-approvals-and-sandbox \
    - \
    > ".delegate/tasks/TASK-N.log" 2>&1 &
```
