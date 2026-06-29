# Usage Guide

## Prerequisites

Each skill delegates to a different CLI. Install whichever ones you need:

```bash
npm install -g opencode-ai                       # opencode
bun install -g @earendil-works/pi-coding-agent   # pi
npm install -g @mimo-ai/cli                      # mimo
npm install -g @openai/codex                     # codex
# hermes, kimi, agy: see their respective documentation
```

Verify: `opencode --version`, `pi --version`, `mimo --version`, `codex --version`, etc.

## Invoking a skill

```
/delegate-to-any <task description>       # auto-selects whichever runtime is installed
/delegate-to-opencode <task description>
/delegate-to-pi <task description>
/delegate-to-mimo <task description>
/delegate-to-hermes <task description>
/delegate-to-kimi <task description>
/delegate-to-codex <task description>
/delegate-to-agy <task description>
```

Use `/delegate-to-any` when you don't care which agent runs or want portability across machines. The skill scans for installed runtimes and picks the highest-priority one (oh-my-opencode → opencode → pi → mimo → hermes → kimi → codex → agy).

The task description is plain English. Be specific about what to build, which files are involved, and any conventions or constraints.

## Configuration

### Choosing a model

Override the default model by including `--model` in your request for tools that support it:

```
/delegate-to-opencode --model anthropic/claude-sonnet-4-6 <task>
/delegate-to-pi --model claude-sonnet-4-6 <task>
/delegate-to-codex --model o3 <task>
```

The skill verifies the model ID before launching where possible. Agy does not support a `--model` CLI flag — configure its model in Agy's settings file.

### Timeout tiers

The skill auto-selects a timeout based on task complexity:

| Tier | Task type | Timeout | Poll interval |
|------|-----------|---------|---------------|
| 1 | Single file edit, simple fix, type generation | 10 min | 2 min |
| 2 | New feature with tests, multi-file refactor | 30 min | 6 min |
| 3 | Architecture change, large refactor, migration | 2 hours | 24 min |
| 4 | Multi-phase feature, full integration, cross-repo | 8 hours | 96 min |

Override by stating complexity explicitly: "simple change" → Tier 1, "migration" → Tier 3, etc.

## What gets created

```
your-project/
├── TODO.md                              # shared task ledger (append-only)
└── .opencode/
    ├── tasks/
    │   ├── TASK-N.md                   # handoff document
    │   ├── TASK-N.log                  # agent output
    │   ├── TASK-N.log.size             # log size for stall detection
    │   ├── TASK-N.pid                  # process ID
    │   └── TASK-N.watchdog.pid         # timeout watchdog PID
    └── worktrees/
        └── TASK-N/                     # isolated git checkout
```

After a successful run, merge the worktree (replace `<runtime>` with `opencode`, `pi`, `codex`, etc.):

```bash
git merge <runtime>/TASK-N
git worktree remove .opencode/worktrees/TASK-N
git branch -d <runtime>/TASK-N
```

## Self-healing

The skill monitors the agent and recovers automatically:

| Symptom | What happens |
|---------|--------------|
| Process exits immediately, log < 500 bytes | Reads error, adjusts command, retries (max 2×) |
| Process running but log not growing between polls | Kills it, retries with `--continue` |
| Process exits cleanly but output file missing | Retries with `--continue` |
| Verification fails after output is produced | Retries with `--continue` and notes what failed |
| All retries exhausted | Marks `failed`, reports log tail to you |

Retry count is tracked in `TODO.md` (`retries:` field) and in `.opencode/tasks/TASK-N.retries`.
