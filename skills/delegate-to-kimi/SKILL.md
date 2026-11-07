---
name: delegate-to-kimi
description: Delegates coding tasks to Kimi Code Agent running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to Kimi for background execution.
license: MIT
compatibility: Requires git, bash, and kimi on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.4.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Kimi

Hands a coding task to Kimi Code in the background with git worktree isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

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
# -y / --yolo     → auto-approve regular tool calls (explicit opt-in only)
# --auto          → fully autonomous permission mode (also a bypass — opt-in only)
# -c / --continue → continue the previous session for the working directory
#                   (lowercase -c: there is no -C flag)
# -m / --model    → model alias override
```

**kimi-code ≥ 2.0 changed print mode:** `-p/--prompt` is auto-permission mode
(it never asks; static deny rules still apply) and is **rejected** in
combination with `-y/--yolo`, `--auto` or `--plan`. So on 2.x never pass `-y`
with `-p`: `DELEGATE_ALLOW_UNSAFE_FLAGS` adds nothing, and the worktree is the
only code isolation. The bundled launcher detects the major version with
`kimi --version` and does this for you; the manual block below does the same.

### Safety defaults

Prefer the bundled launcher (`$DELEGATE_SH`, resolved at the top of `workflow.md`).
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

**Preferred — the bundled launcher** (`$DELEGATE_SH`, resolved at the top of [`workflow.md`](workflow.md)):

```bash
bash "$DELEGATE_SH" kimi TASK-N "$TIMEOUT_SECS"     # append --model "<id>" only if the user asked for a model
```

It verifies (or creates) the worktree, applies exactly the flags described in this file, records the real PID, exit code and a PID-reuse fingerprint, and arms a watchdog that cancels itself when the agent exits. Relay its `PID=`, `LOG=` and `WORK_DIR=` lines to the user. Use the manual block below only when no launcher is available.

**Manual fallback:**

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
KIMI_MAJOR=$(kimi --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ "${KIMI_MAJOR:-0}" -ge 2 ] 2>/dev/null; then
  echo "WARN: kimi >= 2 print mode never asks for approval; the worktree is the only isolation." >&2
else
  [ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && UNSAFE_ARGS+=(-y)   # 2.x rejects -y with -p
fi

# Add -m "<model>" only if user specified one
cd "$WORK_DIR" || exit 1
nohup kimi \
  -p "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly." \
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
  "message": "'kimi' not found on PATH.",
  "required": ["kimi"],
  "resolution": "Install Kimi Code CLI and ensure it is on PATH, then retry /delegate-to-kimi."
}
```

Tell the user: task ID, working directory (`$WORK_DIR`), timeout deadline.

### Retry (Step 5 Cases 2–4)

With the launcher (it never resets the retry counter and rotates the old log to `TASK-N.log.prev`):
```bash
bash "$DELEGATE_SH" stop TASK-N                              # no-op if it already exited
bash "$DELEGATE_SH" kimi TASK-N "$TIMEOUT_SECS" --continue   # resumes the previous session in the worktree
```

Manual fallback (reuse the variables from the initial launch):
```bash
# The previous attempt must already be stopped (Step 5 Case 2). Cancel its
# watchdog, keep its log for diagnosis, then relaunch and re-arm.
kill "$(cat "$PROJECT_ROOT/.delegate/tasks/TASK-N.watchdog.pid" 2>/dev/null)" 2>/dev/null
mv -f "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" "$PROJECT_ROOT/.delegate/tasks/TASK-N.log.prev" 2>/dev/null
cd "$WORK_DIR" || exit 1
nohup kimi \
  -p "Continue the task from where you left off. Task file: $TASK_FILE" \
  -c ${UNSAFE_ARGS[@]+"${UNSAFE_ARGS[@]}"} \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.delegate/tasks/TASK-N.pid"
nohup bash -c 'sleep "$1"; kill -TERM "$2" 2>/dev/null; sleep 30; kill -KILL "$2" 2>/dev/null' \
  _ "$TIMEOUT_SECS" "$TASK_PID" > /dev/null 2>&1 &
echo $! > "$PROJECT_ROOT/.delegate/tasks/TASK-N.watchdog.pid"
```
