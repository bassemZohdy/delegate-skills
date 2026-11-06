---
name: delegate-to-any
description: Delegates coding tasks to whichever agent CLI is available on the system — automatically selects the best installed runtime (oh-my-opencode, opencode, pi, mimo, hermes, kimi, codex, agy) by priority order. Use this when you don't care which agent runs the task, or when you want maximum portability across machines with different tools installed.
license: MIT
compatibility: "Requires git, bash, and at least one of: oh-my-opencode, opencode, pi, mimo, hermes, kimi, codex, or agy on PATH."
metadata:
  author: Bassem Zohdy
  version: 1.4.0
  category: delegation
disable-model-invocation: true
argument-hint: "[--model <model-id>] <task description>"
---

# Delegate to Any (Auto-Router)

Scans available agent CLIs, picks the best one, and delegates the task using the git worktree isolation workflow.

## Task

$ARGUMENTS

Follow the shared workflow in [`workflow.md`](workflow.md) for Steps −1 through 3 and Step 5. This file defines only **Step 4** — runtime detection, selection, and launch.

Before proceeding: if `workflow.md` does not exist in this same folder, the skill was installed incompletely (a partial file copy). Stop and tell the user to reinstall this skill, rather than improvising the workflow from memory.

---

## Step 4: Detect, Select, and Launch

### Detect All Available Runtimes

Run a single scan across all supported binaries:

```bash
for bin in oh-my-opencode oh-my-openagent opencode pi mimo hermes kimi codex agy; do
  command -v "$bin" &>/dev/null && echo "$bin"
done
```

This prints every binary that is on PATH, in priority order.

### Selection Priority

| Priority | Binary | Notes |
|----------|--------|-------|
| 1 | `oh-my-opencode` / `oh-my-openagent` | opencode with the oh-my-opencode plugin — label `omo`, launched through `opencode` |
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
  "checked": ["oh-my-opencode", "oh-my-openagent", "opencode", "pi", "mimo", "hermes", "kimi", "codex", "agy"],
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
- **mimo**: `mimo models 2>&1 | grep -i "<model>"`
- **hermes**: no list command — check hermes config; a wrong name fails at startup (Case 1)
- **kimi**: no list command — model aliases come from kimi's `config.toml`; a wrong name fails at startup (Case 1)
- **codex**: no list command — the name configured for its provider; a wrong name fails at startup (Case 1)
- **agy**: `agy models 2>&1 | grep -i "<model>"`

Pass the verified ID to the launcher as `--model "<id>"`.

If no model was requested, omit the model flag entirely for all runtimes.

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

Use the launch pattern for the chosen runtime. Two equivalent paths:

1. **Preferred — the bundled launcher** (`$DELEGATE_SH`, resolved at the top of [`workflow.md`](workflow.md); this skill ships its own copy at `scripts/delegate.sh`, so it is always available). It encapsulates worktree verification, the right flags per runtime, PID/retries files, and a self-cancelling watchdog for all seven runtime binaries:
   ```bash
   bash "$DELEGATE_SH" <selected-runtime> TASK-N "$TIMEOUT_SECS"   # append --model "<id>" only if requested
   ```
   Where `<selected-runtime>` is the binary chosen above (`opencode`, `pi`, `mimo`, `hermes`, `kimi`, `codex`, or `agy`). For `oh-my-opencode` / `oh-my-openagent`: it is an opencode plugin, so launch `opencode` through the launcher (the plugin still loads) and record `agent: omo` in TODO.md — the worktree branch stays `opencode/TASK-N`, which is what the launcher verifies; only if you need the `oh-my-opencode run` entry point itself (it waits for the session's todos and sub-sessions before exiting), use path 2.

2. **Direct launch** — copy the exact Launch block from the chosen runtime's own skill, if it is installed alongside this one (sibling folders under the same skills root): `../delegate-to-opencode/SKILL.md` (opencode/omo), `../delegate-to-pi/SKILL.md`, `../delegate-to-mimo/SKILL.md`, `../delegate-to-hermes/SKILL.md`, `../delegate-to-kimi/SKILL.md`, `../delegate-to-codex/SKILL.md`, `../delegate-to-agy/SKILL.md`. A single-skill install may not have them — then path 1 is the only supported launch.

   The per-runtime skill is the **single source of truth** for each runtime's flags and handoff-delivery mechanism (`--file`, `@path`, stdin, or absolute-path-in-prompt). Do not paraphrase it — copy the block verbatim. This avoids the drift that occurs when launch commands are maintained in two places.

Every per-runtime launch block shares the same mechanical skeleton (shown once here so the common parts are auditable in one place). The runtime-specific line is the `nohup <runtime> ...` invocation; everything else is identical across runtimes:

```bash
# Common skeleton — the runtime-specific nohup line comes from the per-runtime skill.
PROJECT_ROOT="$(pwd)"                       # capture BEFORE any cd (most runtimes cd into the worktree)
WORK_DIR="$PROJECT_ROOT/.delegate/worktrees/TASK-N"
if [ ! -d "$WORK_DIR" ]; then
  [ "${DELEGATE_ALLOW_UNISOLATED:-0}" = 1 ] || { echo "ERROR: worktree missing; refusing unisolated launch" >&2; exit 1; }
  echo "WARN: explicitly running without code isolation" >&2
  WORK_DIR="$PROJECT_ROOT"
fi
mkdir -p "$PROJECT_ROOT/.delegate/tasks"    # ensure PID/log/retries files can be written
TIMEOUT_SECS=<seconds from timeout tier>

# >>> Insert the chosen runtime's nohup launch line here (from delegate-to-<runtime>/SKILL.md).
# >>> It must background with '&' and redirect to the log path below.
# >>> Use $PROJECT_ROOT-absolute paths for --file — --dir changes the runtime's cwd
# >>> to the worktree, so a relative --file path silently fails to resolve.
# >>> e.g. opencode:
# nohup opencode run "..." --file "$PROJECT_ROOT/.delegate/tasks/TASK-N.md" --dir "$WORK_DIR" \
#   $OPENCODE_AUTO_FLAG > "$PROJECT_ROOT/.delegate/tasks/TASK-N.log" 2>&1 &

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

Name the worktree branch after the binary that runs the task (`opencode/TASK-N`, `pi/TASK-N`, …) — never after the `omo` label: an oh-my-opencode task runs through `opencode`, and the launcher refuses a worktree on any other branch. `omo` goes only in the TODO.md `agent:` field.

Tell the user: selected runtime, task ID, working directory, log path, timeout deadline.

### Retry (Step 5 Cases 2–4)

The chosen runtime does not change on retry. With the launcher:
```bash
bash "$DELEGATE_SH" stop TASK-N                                       # no-op if it already exited
bash "$DELEGATE_SH" <selected-runtime> TASK-N "$TIMEOUT_SECS" --continue
```
Otherwise use the Retry block from the selected runtime's own `../delegate-to-<runtime>/SKILL.md`.
