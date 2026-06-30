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

Use the launch pattern for the chosen runtime. Two equivalent paths:

1. **Preferred — use the shared launcher** (encapsulates worktree reuse, the right flags per runtime, PID/retries files, and the watchdog for all eight runtimes):
   ```bash
   bash scripts/delegate.sh <selected-runtime> TASK-N $TIMEOUT_SECS
   ```
   Where `<selected-runtime>` is the binary chosen above (`opencode`, `pi`, `mimo`, `hermes`, `kimi`, `codex`, or `agy`). For `oh-my-opencode`, use path 2 below — `delegate.sh` targets the `opencode` binary specifically.

2. **Direct launch** — copy the exact Launch block from the chosen runtime's own skill: [`delegate-to-<runtime>/SKILL.md`](delegate-to-opencode/SKILL.md) (opencode/omo), [`delegate-to-pi`](delegate-to-pi/SKILL.md), [`delegate-to-mimo`](delegate-to-mimo/SKILL.md), [`delegate-to-hermes`](delegate-to-hermes/SKILL.md), [`delegate-to-kimi`](delegate-to-kimi/SKILL.md), [`delegate-to-codex`](delegate-to-codex/SKILL.md), [`delegate-to-agy`](delegate-to-agy/SKILL.md).

   The per-runtime skill is the **single source of truth** for each runtime's flags and handoff-delivery mechanism (`--file`, `@path`, stdin, or absolute-path-in-prompt). Do not paraphrase it — copy the block verbatim. This avoids the drift that occurs when launch commands are maintained in two places.

Every per-runtime launch block shares the same mechanical skeleton (shown once here so the common parts are auditable in one place). The runtime-specific line is the `nohup <runtime> ...` invocation; everything else is identical across runtimes:

```bash
# Common skeleton — the runtime-specific nohup line comes from the per-runtime skill.
PROJECT_ROOT="$(pwd)"                       # capture BEFORE any cd (pi/hermes/kimi/agy cd into the worktree)
WORK_DIR="$PROJECT_ROOT/.opencode/worktrees/TASK-N"
[ ! -d "$WORK_DIR" ] && WORK_DIR="$PROJECT_ROOT"
mkdir -p "$PROJECT_ROOT/.opencode/tasks"    # ensure PID/log/retries files can be written
TIMEOUT_SECS=<seconds from timeout tier>

# >>> Insert the chosen runtime's nohup launch line here (from delegate-to-<runtime>/SKILL.md).
# >>> It must background with '&' and redirect to the log path below.
# >>> e.g. opencode:
# nohup opencode run "..." --file ".opencode/tasks/TASK-N.md" --dir "$WORK_DIR" \
#   --dangerously-skip-permissions > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &

TASK_PID=$!
echo $TASK_PID > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
echo 0 > "$PROJECT_ROOT/.opencode/tasks/TASK-N.retries"

# Watchdog: SIGTERM after timeout, SIGKILL after 30s grace
(sleep $TIMEOUT_SECS && kill -TERM $TASK_PID 2>/dev/null \
  && sleep 30 && kill -KILL $TASK_PID 2>/dev/null) &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.watchdog.pid"
```

Use the runtime label in TODO.md and on the worktree branch name: `omo` for oh-my-opencode, otherwise the binary name (`opencode`, `pi`, `mimo`, `hermes`, `kimi`, `codex`, `agy`).

Tell the user: selected runtime, task ID, working directory, log path, timeout deadline.

### Retry (Step 5 Case 2)

Use the `--continue` pattern from the selected runtime's own `delegate-to-<runtime>/SKILL.md`. The chosen runtime does not change on retry.
