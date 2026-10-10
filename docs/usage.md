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
└── .delegate/
    ├── todo.lock/                       # transient — held only during `next-id`
    ├── tasks/
    │   ├── TASK-N.md                   # handoff document
    │   ├── TASK-N.log                  # agent output
    │   ├── TASK-N.log.size             # log size for stall detection (status)
    │   ├── TASK-N.lastpoll             # mtime marker for the filesystem-activity
    │   │                                # stall signal (status)
    │   ├── TASK-N.pid                  # real agent process ID
    │   ├── TASK-N.watchdog.pid         # supervisor process ID (launched via
    │   │                                # scripts/delegate.sh only — see below)
    │   ├── TASK-N.exitcode             # agent's real exit code, once it exits
    │   ├── TASK-N.fingerprint          # best-effort process identity, guards
    │   │                                # against a later kill hitting a reused PID
    │   ├── TASK-N.pgid                 # process-group id, only written when
    │   │                                # verified safe to use for a group kill
    │   ├── TASK-N.supervisor.sh        # the generated supervisor script (kept
    │   │                                # for inspection)
    │   ├── TASK-N.verify.log           # output of the last `verify` run
    │   └── TASK-N.retries              # self-healing retry counter
    └── worktrees/
        └── TASK-N/                     # isolated git checkout
```

## `scripts/delegate.sh` subcommands

If you copied `helpers/scripts/delegate.sh` into your project (see `docs/install.md`), it does more than launch — it's the preferred way to monitor and manage tasks too, since it captures information a model re-deriving the workflow from prose cannot (a real exit code, a verified process identity):

```bash
bash scripts/delegate.sh <runtime> TASK-N [timeout-secs]   # launch (unchanged)
bash scripts/delegate.sh status TASK-N                     # machine-readable status
bash scripts/delegate.sh verify TASK-N                     # run the handoff's ```bash verification block
bash scripts/delegate.sh reconcile                         # find in_progress tasks orphaned by a crashed session
bash scripts/delegate.sh next-id                           # allocate the next TASK-N (lock-protected)
```

`status` prints `STATE=RUNNING`, `STATE=STALLED`, `STATE=EXITED_OK`, `STATE=EXITED_FAILED` (with `EXITCODE=`), `STATE=LAUNCH_FAILED`, or `STATE=NOT_FOUND`. Launched tasks run inside a small supervisor process that is the agent's real parent — it captures the agent's true exit code via `wait` (not a guess from "the process disappeared"), races the timeout against natural completion and auto-cancels the timer the instant the agent exits, and is itself launched with `nohup` so it survives the calling terminal closing.

`reconcile` exists because a delegated task's `TODO.md` entry stays `status: in_progress` forever if the AI session that launched it crashes or closes before reviewing completion — nothing else would ever come back to mark it done or failed. Run it at the start of a session before delegating more work.

The skill commits `TODO.md` itself at two points — right after the ledger entry is added (before the worktree is created, so the worktree branches from a commit that already includes it) and again when the task is marked completed. This keeps the main tree clean between delegations and means the merge below never touches `TODO.md`. Merging the worktree's actual code changes is left to you — the skill won't do this automatically since it changes your current branch.

After a successful run, merge the worktree (replace `<runtime>` with `opencode`, `pi`, `codex`, etc.):

```bash
git merge <runtime>/TASK-N
git worktree remove .delegate/worktrees/TASK-N
git branch -d <runtime>/TASK-N
```

## Self-healing

The skill monitors the agent and recovers automatically (via `scripts/delegate.sh status`/`verify` when present, otherwise the same decision tree run manually):

| Symptom | What happens |
|---------|--------------|
| Process exits immediately, log < 500 bytes | Reads error, adjusts command, retries (max 2×) |
| Process running, log flat AND no newer files in the worktree since the last poll | Kills it, retries with `--continue` |
| Process exits cleanly but output file missing | Retries with `--continue` |
| Verification fails after output is produced | Retries with `--continue` and notes what failed |
| All retries exhausted | Marks `failed`, reports log tail to you |
| A prior session crashed mid-task, leaving `status: in_progress` forever | `scripts/delegate.sh reconcile` finds it; mark `stale` and resume with `--continue` |

Retry count is tracked in `TODO.md` (`retries:` field) and in `.delegate/tasks/TASK-N.retries`.

Killing a stalled or timed-out process (`scripts/delegate.sh` launches only) is itself resilient: it never signals a PID that no longer matches the process fingerprint recorded at launch (guards against an unrelated process reusing that PID), and it terminates the agent's child processes too, not just the single top-level PID.

## Launch safety and compatibility

`helpers/scripts/delegate.sh` omits automatic permission-bypass flags and refuses
to launch if a verified git worktree cannot be created or reused. Codex uses the
`workspace-write` sandbox. A runtime may still refuse an operation or wait for
an approval in background mode; inspect its log rather than enabling bypasses
automatically. Host configuration and each runtime's own policies still apply.
This helper does not add permission checks or an OS sandbox to a runtime that
lacks them.

Two independent, per-launch opt-ins are available:

```bash
# Accept edits in the original project if no worktree can be created.
DELEGATE_ALLOW_UNISOLATED=1 bash helpers/scripts/delegate.sh pi TASK-1 1800

# Explicitly accept runtime permission bypass in a controlled environment.
DELEGATE_ALLOW_UNSAFE_FLAGS=1 bash helpers/scripts/delegate.sh pi TASK-1 1800
```

Both variables accept only `0` (default) or `1`. The second enables supported
OpenCode `--auto`/legacy skip-permissions, Pi `--approve`, MiMo skip-permissions,
Hermes YOLO/hook acceptance, Kimi YOLO, Codex approval/sandbox bypass or Agy
skip-permissions. Opt-in is never inferred from worktree availability or retry.
Git worktrees separate code edits; **they are not an OS security boundary**.
They share repository metadata and do not constrain processes, secrets, network
access or host filesystem access. Use an independently configured sandbox when
those restrictions are needed.

Task IDs must be `TASK-N` with positive decimal N; timeouts must be positive
decimal integers. Delegation directories/state files may not be symlinks, and
an existing worktree must match this repository and `<runtime>/TASK-N` branch.
These checks guard accidental traversal/reuse; they do not defend against a
concurrent hostile process modifying paths after validation.

Maintain `skills/` as the source and run `bash helpers/scripts/sync-skills.sh`
after edits. `--check` verifies distributed workflow copies and `.agents/skills/`
without writing files. Copies remain self-contained for single-skill installs.
No root license file is added in this change: the existing MIT declarations
remain subject to the owner's licensing/provenance review.
