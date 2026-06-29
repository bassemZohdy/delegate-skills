---
name: delegate-to-any
description: Delegates coding tasks to whichever agent CLI is available on the system — automatically selects the best installed runtime (oh-my-opencode, opencode, pi, mimo, hermes, kimi, codex, agy) by priority order. Use this when you don't care which agent runs the task, or when you want maximum portability across machines with different tools installed.
license: MIT
compatibility: Requires git, bash, and at least one of: oh-my-opencode, opencode, pi, mimo, hermes, kimi, codex, or agy on PATH.
metadata:
  author: Bassem Zohdy
  version: 1.0.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Any (Auto-Router)

Scans available agent CLIs, picks the best one, and delegates the task using the full isolation workflow.

## Task

$ARGUMENTS

Follow the shared workflow in [`../shared/workflow.md`](../shared/workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — runtime detection, selection, and launch.

---

## Step 4: Detect, Select, and Launch

### Detect All Available Runtimes

Run a single scan across all supported binaries:

```bash
for bin in oh-my-opencode opencode pi mimo hermes kimi codex agy; do
  command -v "$bin" &>/dev/null && echo "$bin"
done
```

This prints every binary that is on PATH, in priority order.

### Selection Priority

| Priority | Binary | Notes |
|----------|--------|-------|
| 1 | `oh-my-opencode` | Preferred opencode variant — use `omo` launch path |
| 2 | `opencode` | Standard opencode |
| 3 | `pi` | |
| 4 | `mimo` | |
| 5 | `hermes` | |
| 6 | `kimi` | |
| 7 | `codex` | |
| 8 | `agy` | |

Take the **first hit** from the list above. Tell the user which runtime was selected and why (first available by priority).

### If No Runtime Found

```json
{
  "error": "missing_runtime",
  "message": "No supported agent CLI found on PATH.",
  "checked": ["oh-my-opencode", "opencode", "pi", "mimo", "hermes", "kimi", "codex", "agy"],
  "install_options": [
    "opencode  →  npm install -g opencode-ai",
    "pi        →  bun install -g @earendil-works/pi-coding-agent",
    "mimo      →  npm install -g @mimo-ai/cli",
    "codex     →  npm install -g @openai/codex",
    "hermes    →  see Hermes Agent documentation",
    "kimi      →  see Kimi Code documentation",
    "agy       →  see Agy documentation"
  ],
  "resolution": "Install any one of the above, ensure it is on PATH, then retry /delegate-to-any."
}
```

Stop immediately. Do not proceed to git preflight or create any files.

### Validate Model and Flags

Only if the user explicitly requested a model — validate against the chosen runtime:

- **oh-my-opencode / opencode**: `opencode models 2>&1 | grep -i "<model>"`
- **pi**: `pi --list-models 2>&1 | grep -i "<model>"`
- **mimo**: check mimo docs / config
- **hermes**: check hermes docs / config — no CLI list command
- **kimi**: check kimi docs / config
- **codex**: uses OpenAI model names (`o3`, `o4-mini`, `gpt-4o`) — no list command, errors on start if wrong
- **agy**: model selection is config-only, cannot be passed via CLI

If no model was requested, omit the model flag entirely for all runtimes.

### Launch

Use the launch pattern for the chosen runtime. In all patterns below, `TASK-N` refers to the task ID determined in Step 1, `WORK_DIR` / `TASK_FILE` / `PROJECT_ROOT` are as established in the shared workflow, and `TIMEOUT_SECS` is the value selected from the timeout tiers in `docs/usage.md`.

---

**`oh-my-opencode` (omo):**

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

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

Use `omo` as the runtime label in TODO.md and on the worktree branch name.

---

**`opencode`:**

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

nohup opencode run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  --file ".opencode/tasks/TASK-N.md" \
  --dir "$WORK_DIR" \
  --dangerously-skip-permissions \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

Alternatively: `bash scripts/delegate.sh opencode TASK-N $TIMEOUT_SECS`

---

**`pi`:**

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

cd "$WORK_DIR" && nohup pi -p \
  "@$PROJECT_ROOT/.opencode/tasks/TASK-N.md" \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  --approve \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
```

---

**`mimo`:**

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

MIMO_HELP=$(mimo run --help 2>&1)
MIMO_DIR_FLAG="";  echo "$MIMO_HELP" | grep -q -- "--dir"  && MIMO_DIR_FLAG="--dir $WORK_DIR"
MIMO_SKIP_FLAG=""; echo "$MIMO_HELP" | grep -q "skip-permissions" && MIMO_SKIP_FLAG="--dangerously-skip-permissions"
MIMO_FILE_FLAG=""; echo "$MIMO_HELP" | grep -q -- "--file" && MIMO_FILE_FLAG="--file .opencode/tasks/TASK-N.md"

# shellcheck disable=SC2086
nohup mimo run \
  "Execute the task described in the attached handoff document. Follow all instructions in it exactly." \
  $MIMO_FILE_FLAG $MIMO_DIR_FLAG $MIMO_SKIP_FLAG \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

---

**`hermes`:**

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"

cd "$WORK_DIR" && nohup hermes chat \
  -q "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly." \
  --yolo --accept-hooks -Q \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
```

---

**`kimi`:**

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"

cd "$WORK_DIR" && nohup kimi \
  -p "Read $TASK_FILE and execute the task described in it. Follow all instructions exactly." \
  -y \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
```

---

**`codex`:**

```bash
WORK_DIR=".opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="."

TASK_FILE=".opencode/tasks/TASK-N.md"

export _CODEX_WORK_DIR="$WORK_DIR"
export _CODEX_TASK_FILE="$TASK_FILE"
nohup bash -c \
  'codex exec -C "$_CODEX_WORK_DIR" -s danger-full-access --dangerously-bypass-approvals-and-sandbox - < "$_CODEX_TASK_FILE"' \
  > ".opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > ".opencode/tasks/TASK-N.pid"
echo 0 > ".opencode/tasks/TASK-N.retries"
unset _CODEX_WORK_DIR _CODEX_TASK_FILE

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > ".opencode/tasks/TASK-N.watchdog.pid"
```

---

**`agy`:**

```bash
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"

TASK_FILE="$PROJECT_ROOT/.opencode/tasks/TASK-N.md"

nohup agy \
  --print "Read $TASK_FILE and execute the task described in it. All file changes must be made inside $WORK_DIR. Follow all instructions exactly." \
  --add-dir "$WORK_DIR" \
  --dangerously-skip-permissions \
  > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
```

---

Tell the user: selected runtime, task ID, working directory, log path, timeout deadline.

### Retry (Step 5 Case 2)

Use the `--continue` pattern from the selected runtime's own `delegate-to-<runtime>/SKILL.md`. The chosen runtime does not change on retry.
