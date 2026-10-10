---
name: delegate-to-codex
description: Delegates coding tasks to OpenAI Codex CLI running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Codex for background execution.
license: MIT
compatibility: Requires git, bash, and codex on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.3.1
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Codex

Hands a coding task to OpenAI Codex CLI in the background with git worktree isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

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
# -s workspace-write → keep filesystem sandboxing enabled
# --dangerously-bypass-approvals-and-sandbox → opt-in only, not required by this skill
# codex exec resume --last → resume most recent session
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

**Critical: pipe a framing instruction followed by the handoff via stdin.** Codex `exec ... -` reads stdin as the instruction set. Sending the raw handoff with no framing risks Codex treating the markdown as content to discuss rather than a task to execute. Prepend a one-line directive so the role of the handoff is unambiguous.

**Critical: codex must be the last element of the backgrounded pipeline.** `$!` is the PID of the last pipeline command — putting codex last makes the watchdog and liveness checks target codex itself. (Wrapping the whole pipeline in a backgrounded `bash -c` string captures the wrapper shell's PID instead; SIGTERM to that shell does not propagate to the piped codex child, so timeouts leave codex running.)

```bash
WORK_DIR=".delegate/worktrees/TASK-N"
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="."
fi

TASK_FILE=".delegate/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>
CODEX_SECURITY_ARGS=(-s workspace-write)
[ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && CODEX_SECURITY_ARGS=(--dangerously-bypass-approvals-and-sandbox)

# Add -m "<model>" only if user specified one.
{ printf '%s\n\n' "Execute the task described in the handoff document below. Follow all instructions in it exactly."; \
  cat "$TASK_FILE"; } | \
  nohup codex exec -C "$WORK_DIR" \
    ${CODEX_SECURITY_ARGS[@]+"${CODEX_SECURITY_ARGS[@]}"} \
    - \
    > ".delegate/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".delegate/tasks/TASK-N.pid"
echo 0 > ".delegate/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace. nohup'd (via a
# positional-arg bash -c, to dodge quoting issues) so it survives the calling
# terminal/session closing — a bare backgrounded subshell is not guaranteed to.
nohup bash -c 'sleep "$1"; kill -TERM "$2" 2>/dev/null; sleep 30; kill -KILL "$2" 2>/dev/null' \
  _ "$TIMEOUT_SECS" "$TASK_PID" > /dev/null 2>&1 &
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
    ${CODEX_SECURITY_ARGS[@]+"${CODEX_SECURITY_ARGS[@]}"} \
    - \
    > ".delegate/tasks/TASK-N.log" 2>&1 &
```
