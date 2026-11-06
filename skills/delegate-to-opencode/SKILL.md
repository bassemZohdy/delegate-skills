---
name: delegate-to-opencode
description: Delegates coding tasks to opencode (or oh-my-opencode) running in a background process with an isolated git worktree. Tracks all tasks and sub-tasks in TODO.md and periodically reviews completion. Use this whenever you want to hand off implementation, refactoring, test generation, or migration work to opencode for background execution.
license: MIT
compatibility: Requires git, bash, and opencode or oh-my-opencode on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.4.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to OpenCode

Hands a coding task to opencode in the background with git worktree isolation, structured context, and ongoing review.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — the runtime-specific detection and launch logic.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

---

## Step 4: Detect Runtime and Launch in Background

### Detect

```bash
if command -v oh-my-opencode &>/dev/null || command -v oh-my-openagent &>/dev/null; then
  echo "omo"      # opencode with the oh-my-opencode plugin (both bins come from one package)
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
opencode run --help 2>&1 | grep -E "variant|effort|thinking"
# '--variant <level>' present → provider-specific reasoning effort (e.g. high, max, minimal)
# '--thinking' is a boolean that only SHOWS thinking blocks — it is not an effort level
# 'effort' not present → never use it
```
`--file` is an array option (`[array]` in the help): it consumes following non-flag words, so never put the message or another positional after it.

**oh-my-opencode's own runner has different flags** (verified against oh-my-openagent 5.1.62, `docs/reference/cli.md`):
```bash
oh-my-opencode run --help 2>&1 | grep -E "directory|model|session-id"
# -d, --directory <path>          → working directory (NOT --dir)
# -m, --model <provider/model>    → model override
# --session-id <id>               → resume an existing session (there is no --continue)
# no --file, no --yes, no approval-bypass flag: permissions come from opencode's own config
```

**Auto-approval flag** — disabled by default; explicit opt-in only. The flag name has changed across opencode versions (`--dangerously-skip-permissions` was replaced by `--auto` as of v1.17.x) — never hardcode one, detect it. Check the deprecated flag first so `--auto` wins when a version supports both:
```bash
OPENCODE_HELP=$(opencode run --help 2>&1)
OPENCODE_AUTO_FLAG=""
[ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && echo "$OPENCODE_HELP" | grep -q -- "--dangerously-skip-permissions" && OPENCODE_AUTO_FLAG="--dangerously-skip-permissions"
[ "${DELEGATE_ALLOW_UNSAFE_FLAGS:-0}" = 1 ] && echo "$OPENCODE_HELP" | grep -q -- "--auto" && OPENCODE_AUTO_FLAG="--auto"
# If neither is present, omit the flag — the run may then block on interactive prompts.
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

**Preferred — the bundled launcher** (`$DELEGATE_SH`, resolved at the top of [`workflow.md`](workflow.md)):

```bash
bash "$DELEGATE_SH" opencode TASK-N "$TIMEOUT_SECS"     # append --model "<id>" only if the user asked for a model
```

It verifies (or creates) the worktree, applies exactly the flags described in this file (for `oh-my-opencode`, see the `omo` note below), records the real PID, exit code and a PID-reuse fingerprint, and arms a watchdog that cancels itself when the agent exits. Relay its `PID=`, `LOG=` and `WORK_DIR=` lines to the user. Use the manual block below only when no launcher is available.

**Manual fallback:**

**Critical: never expand the handoff document into a shell variable.** Multi-line markdown with special characters (`#`, backticks, quotes, brackets) breaks positional argument parsing cross-platform. Instead, attach the handoff file with `--file` and pass a short prompt as the message.

**`opencode`:**
```bash
# Capture PROJECT_ROOT first — --dir points opencode's cwd at the worktree, so any
# relative path (e.g. --file) would otherwise resolve inside the worktree instead
# of the project root, where .delegate/tasks/ actually lives.
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="$PROJECT_ROOT"
fi

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

**`omo` — oh-my-opencode / oh-my-openagent:** an opencode plugin with its own non-interactive runner. `bash "$DELEGATE_SH" opencode ...` already runs with the plugin loaded (opencode loads installed plugins), so the launcher stays the preferred path, and the worktree branch is `opencode/TASK-N` either way — `omo` is only the `agent:` label in TODO.md. Use the manual block below only when you specifically want the `oh-my-opencode run` entry point (it exits only once the session's todos and sub-sessions are finished). Its flags are listed under "Validate Model and Flags" above: `--directory`, not `--dir`; no `--file`, so the handoff is referenced by absolute path in the message; no `--yes` or approval-bypass flag — permissions come from opencode's own config.
```bash
# Capture PROJECT_ROOT first — the block cds into the worktree, so every
# .delegate/tasks/ path must be absolute or it resolves inside the worktree.
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"     # branch opencode/TASK-N
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="$PROJECT_ROOT"
fi

TASK_FILE="$PROJECT_ROOT/.delegate/tasks/TASK-N.md"
TIMEOUT_SECS=<seconds from timeout tier>

# Help-check the directory flag (it is --directory; older builds may lack it —
# the cd below keeps the agent in the worktree regardless). Build args as an
# ARRAY so a path with spaces survives; ${arr[@]+...} keeps an empty array safe
# under `set -u`. Add -m "<provider/model>" only if the user asked for a model.
OMO_HELP=$(oh-my-opencode run --help 2>&1)
OMO_ARGS=()
echo "$OMO_HELP" | grep -q -- "--directory" && OMO_ARGS+=(--directory "$WORK_DIR")

cd "$WORK_DIR" || exit 1    # the process cwd is what contains relative writes
nohup oh-my-opencode run \
  "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly. All changes must stay in $WORK_DIR." \
  ${OMO_ARGS[@]+"${OMO_ARGS[@]}"} \
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
  "message": "Neither 'oh-my-opencode' nor 'opencode' found on PATH.",
  "required": ["oh-my-opencode", "opencode"],
  "resolution": "Install one and ensure it is on PATH, then retry /delegate-to-opencode."
}
```

Tell the user: task ID, which binary launched, working directory, timeout deadline.

### Retry (Step 5 Cases 2–4)

With the launcher (it never resets the retry counter and rotates the old log to `TASK-N.log.prev`):
```bash
bash "$DELEGATE_SH" stop TASK-N                              # no-op if it already exited
bash "$DELEGATE_SH" opencode TASK-N "$TIMEOUT_SECS" --continue   # resumes the previous session in the worktree
```

Manual fallback (reuse the variables from the initial launch):
```bash
# The previous attempt must already be stopped (Step 5 Case 2). Cancel its
# watchdog, keep its log for diagnosis, then relaunch and re-arm.
kill "$(cat "$PROJECT_ROOT/.delegate/tasks/TASK-N.watchdog.pid" 2>/dev/null)" 2>/dev/null
mv -f "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" "$PROJECT_ROOT/.delegate/tasks/TASK-N.log.prev" 2>/dev/null
nohup opencode run \
  "Continue the task from where you left off. The original handoff document is attached." \
  --dir "$WORK_DIR" \
  --continue \
  $OPENCODE_AUTO_FLAG \
  --file "$PROJECT_ROOT/.delegate/tasks/TASK-N.md" \
  > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &
TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.delegate/tasks/TASK-N.pid"
nohup bash -c 'sleep "$1"; kill -TERM "$2" 2>/dev/null; sleep 30; kill -KILL "$2" 2>/dev/null' \
  _ "$TIMEOUT_SECS" "$TASK_PID" > /dev/null 2>&1 &
echo $! > "$PROJECT_ROOT/.delegate/tasks/TASK-N.watchdog.pid"
# omo: `oh-my-opencode run` has no --continue. Prefer the launcher's resume
# (`bash "$DELEGATE_SH" opencode TASK-N "$TIMEOUT_SECS" --continue` — the plugin
# loads in opencode's resumed session). Manually: re-run the omo block with the
# message "Continue the task from where you left off. The handoff is at $TASK_FILE."
# and add `--session-id <id>` if the previous log printed one.
```
