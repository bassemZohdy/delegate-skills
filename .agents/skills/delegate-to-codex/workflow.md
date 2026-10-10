# Delegation Workflow

Shared workflow for all `delegate-to-*` skills. Each skill's `SKILL.md` references this document and adds its own Step 4 (runtime-specific launch logic).

The user's task description is available as `$ARGUMENTS` — it is substituted into the skill body's `## Task` section before the workflow runs. Reference it throughout this workflow wherever the task description is needed (handoff document, TODO.md title, worktree naming). Not every agentskills.io-compliant host performs this substitution — if the `## Task` section still literally reads `$ARGUMENTS` when you read it, treat the user's original request text as the task description instead of proceeding with the literal string.

**Prefer `scripts/delegate.sh` throughout this workflow whenever it exists in the project.** It handles exit-code capture (not just "the process is gone"), safe process-tree termination (won't kill an unrelated process that reuses a PID), and self-cancelling watchdogs — mechanics that are hard to replicate reliably in prose executed live by a model. Steps below call this out at each point it applies; where `scripts/delegate.sh` is absent, fall back to the manual instructions given.

---

## Step −1: Runtime Preflight

**Run this before touching git or writing any files.**

Each skill's `SKILL.md` defines a **Detect** block in Step 4. Run it now:

```bash
# (copy the Detect block from Step 4 of the active skill's SKILL.md and run it here)
```

- Result is a named runtime (e.g. `opencode`, `omo`, `pi`) → proceed to Step 0.
- Result is `none` → output the `missing_runtime` JSON defined in Step 4 of the skill and **stop immediately**. Do not run git preflight, create worktrees, write TODO.md, or write any files.

This guardrail prevents wasted work: a missing binary is caught in one shell command rather than after Steps 0–3 have already modified the repository.

---

## Step 0: Git Preflight

**If `scripts/delegate.sh` is present**, check for orphaned work from a prior session first — if the AI session that launched a task crashed or was closed before it could review completion, that task's `TODO.md` entry stays `in_progress` forever, with an `owner` that will never come back to clear it:

```bash
bash scripts/delegate.sh reconcile
```

For each `STALE TASK-N ...` line reported, update that block in `TODO.md`: change `status: in_progress` to `status: stale`, clear the `owner` field, and add a one-line note. This is a normal in-place field update (allowed under the append-only rule — see TODO.md Conventions below), not a new block. A `stale` task's work is still on disk in its worktree and resumable via `--continue` in a future delegation.

```bash
git status --short
```

**Empty output** → working tree is clean, continue.

**Any output** → stop and show the user exactly what changed, then ask:

> "Uncommitted changes in the working tree:
> ```
> <git status --short output>
> ```
> Commit (or `WIP:` commit) first, or continue on a dirty tree?"

- **Commit first** → wait. Do not proceed until the tree is clean.
- **Continue anyway** → set `dirty_tree: true` in the TODO.md entry so the dirty state is traceable if something breaks.

Also capture the baseline now:
```bash
git rev-parse HEAD        # base SHA for the handoff doc
git branch --show-current # current branch name
```

If there are tests in this project, run them once before proceeding and record whether they pass. This establishes the regression baseline — you need to know the starting state to know what the agent broke vs what was already broken.

---

## Step 1: Update TODO.md

`TODO.md` lives at the project root and is the shared ledger for all agents. Create it if it doesn't exist. Append a new block — never edit or delete existing blocks.

**If `scripts/delegate.sh` is present, use it to allocate the task number** — it takes an `mkdir`-based lock around the read-and-increment so two concurrent delegations can't both compute the same `TASK-N` (see the "TODO.md has no lock" note at the bottom of this document):

```bash
TASK_N_LABEL=$(bash scripts/delegate.sh next-id)   # e.g. "TASK-7"
TASK_N="${TASK_N_LABEL#TASK-}"                     # numeric part, for the arithmetic/paths below
```

**Otherwise**, compute it manually (not lock-protected — safe for a single caller, not for concurrent ones):

```bash
# Take the highest existing task number across TODO.md and TODO-ARCHIVE.md
# (completed tasks may have been archived out of TODO.md) and add 1. Using the
# MAX rather than a block count matters: if any block was ever removed despite
# the append-only rule, a count-based ID would collide with a surviving task.
LAST_N=$(grep -h '^## \[TASK-' TODO.md TODO-ARCHIVE.md 2>/dev/null \
  | sed -E 's/^## \[TASK-([0-9]+)\].*/\1/' | sort -n | tail -1)
TASK_N=$(( ${LAST_N:-0} + 1 ))
```

```markdown
## [TASK-N] <short title>
- status: in_progress
- owner: <agent>/<ISO-timestamp>
- agent: <runtime> / <resolved model ID, or "default" if none specified>
- started: <ISO-8601>
- timeout: <chosen from timeout tiers — see docs/usage.md>
- worktree: .delegate/worktrees/TASK-N   # or "none"
- branch: <runtime>/TASK-N               # e.g. opencode/TASK-1, pi/TASK-2 — or "none"
- base_sha: <git rev-parse HEAD output>  # or "none"
- dirty_tree: false
- handoff: .delegate/tasks/TASK-N.md
- output_ref: <where the agent should write its result>
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
<what progress looks like while the task is running — e.g. "TypeScript files being created under src/models/", "test suite being extended in __tests__/">

### Sub-tasks
- [ ] <sub-task 1>
- [ ] <sub-task 2>

### Verification
<explicit done criteria: exact commands to run, files that must exist, outputs to validate>
```

The `active_form` field is critical — it tells a reviewing agent what to look for in the log and filesystem before the task exits. Without it, agents mark tasks done the moment the process stops rather than when the work is actually complete.

**Commit this ledger entry now**, before creating the worktree:
```bash
git add TODO.md && git commit -m "TASK-N: add ledger entry"
```
This matters for two reasons: (1) it keeps the working tree clean going into Step 2, so Step 0's dirty-tree check doesn't fire on the *next* delegation; (2) the worktree branch created in Step 2 branches off this commit, so the ledger entry is part of the worktree's own history from the start. Worktrees only share *committed* history, not the main tree's uncommitted edits — a `TODO.md` change made after the worktree already exists is invisible inside it. (The delegated agent itself never needs to read `TODO.md` — it works from the handoff document in Step 3, attached by absolute path — but the worktree should never be inconsistent with the ledger entry describing it.) If the project is not a git repo, skip the commit — there's no history to keep consistent.

---

## Step 2: Create a Git Worktree

Parallel agents writing to the same working tree corrupt each other. Create an isolated checkout, branched from the commit just made in Step 1:

```bash
RUNTIME=<opencode|pi|mimo — whichever skill is running>
git worktree add .delegate/worktrees/TASK-$TASK_N -b $RUNTIME/TASK-$TASK_N
```

If the project is not a git repo with a committed HEAD, or worktree creation fails,
stop delegation. Only an explicit operator opt-in (`DELEGATE_ALLOW_UNISOLATED=1`)
permits proceeding on the current working tree; warn that the agent will edit it
directly and record `worktree: none (explicit opt-in)` in TODO.md. Never invent
this opt-in to recover a failure. Git worktrees provide code isolation, not an OS
security sandbox. Keep runtime approvals and sandbox defaults enabled; unsafe
launch flags additionally require `DELEGATE_ALLOW_UNSAFE_FLAGS=1`.

---

## Step 3: Write the Handoff Document

Save to `.delegate/tasks/TASK-N.md`. This is the agent's only briefing — it has no conversation history. Write as if the reader is starting cold.

**Ensure the directory exists before writing** — the launch blocks in Step 4 also write PID/log/retries files into `.delegate/tasks/`, and on a first-ever delegation nothing creates it:
```bash
mkdir -p .delegate/tasks .delegate/worktrees
```

```markdown
# Task Handoff — TASK-N

## Task Description
<what to accomplish, in plain language>

## Target Paths
<all files and directories involved, one per line>

## Worktree Path
.delegate/worktrees/TASK-N   # or "(current directory — explicit unisolated opt-in)"

## Architectural Instructions
<design decisions, patterns, naming conventions, constraints the user specified>

## Sub-tasks
<mirror the sub-task list from TODO.md exactly>

## Active Form
<mirror the active_form from TODO.md — what mid-task progress looks like>

## Verification Expectations
<exact done criteria — test commands to run, outputs to check, files to verify. Where possible, express this as
a fenced ```bash block — `scripts/delegate.sh verify TASK-N` (see Step 5, Case 4) runs it mechanically and
reports PASS/FAIL with the real exit code, instead of a reviewing model having to interpret prose criteria.>

```bash
# example — replace with the real commands for this task
npm test
test -f src/models/user.ts
```

## Git State
- base_branch: <current branch>
- base_sha: <SHA from Step 0>
- agent_branch: <runtime>/TASK-N
- tests_passing_at_start: <true / false from the baseline run>

## Context
<anything else from the conversation the agent needs to know cold>
```

Keep this document complete but tight — 200 to 500 tokens is the target. A context dump of the full conversation degrades downstream reasoning. Include rationale for decisions, not just the decisions themselves.

---

## Step 4: Detect Runtime and Launch in Background

**This step is runtime-specific. See the skill's `SKILL.md` for the exact commands.**

Each skill defines:
1. How to detect if the runtime is installed
2. How to validate the model ID
3. What flags the runtime supports
4. The exact launch command (with `--file` or `@file` for the handoff doc)
5. The `missing_runtime` abort block

---

## Step 5: Periodic Review + Self-Healing

Poll at roughly 20% of the timeout interval (e.g. every 2 min on a 10 min task, every 6 min on a 30 min task). On **each** review cycle, run the full decision tree below in order.

**If `scripts/delegate.sh` is present, check liveness with it instead of the manual commands in part A**:

```bash
bash scripts/delegate.sh status TASK-N
```

This prints `STATE=RUNNING`, `STATE=STALLED`, `STATE=EXITED_OK`, `STATE=EXITED_FAILED` (with `EXITCODE=`), `STATE=LAUNCH_FAILED`, or `STATE=NOT_FOUND`, plus `LOG_SIZE=` and `RETRIES=`. It's a stronger signal than the manual liveness check below in three ways: `STALLED` cross-checks log growth against filesystem activity in the worktree (a healthy agent doing a long silent compile won't be misread as stuck), `EXITED_FAILED` carries the agent's *real* exit code (captured by the supervisor process that launched it, not inferred from "the process is gone"), and none of it risks signaling the wrong process — the PID it reports has already been verified against a fingerprint recorded at launch. Map its `STATE=` directly onto the cases below (`RUNNING`→Case 5, `STALLED`→Case 2, `LAUNCH_FAILED`→Case 1, `EXITED_OK`/`EXITED_FAILED`→Case 3 or 4 depending on whether `output_ref` exists) and skip part A entirely.

**Otherwise**, check liveness manually:

### A. Check liveness

```bash
PID=$(cat .delegate/tasks/TASK-N.pid 2>/dev/null)
kill -0 "$PID" 2>/dev/null && echo "running" || echo "exited"
LOG_SIZE=$(wc -c < ".delegate/tasks/TASK-N.log" 2>/dev/null || echo 0)
PREV_SIZE=$(cat ".delegate/tasks/TASK-N.log.size" 2>/dev/null || echo -1)
echo $LOG_SIZE > ".delegate/tasks/TASK-N.log.size"
```

### B. Self-healing decision tree

Work through each case in order; stop at the first that applies.

---

#### Case 1 — Launch failure (process exited, log < 500 bytes)

The process quit almost immediately with no meaningful output. The most likely cause is a flag or path error at startup.

```bash
RETRIES=$(cat ".delegate/tasks/TASK-N.retries" 2>/dev/null || echo 0)
```

If `RETRIES < 2`:
1. Read the log to find the actual error message.
2. Adjust the launch command based on what the error says (e.g. wrong flag, bad path).
3. Increment retry counter: `echo $((RETRIES + 1)) > .delegate/tasks/TASK-N.retries`
4. Re-launch with the same command structure (Step 4), replacing the watchdog.
5. Update TODO.md: `retries: <new count>`, add a note under the block explaining what changed.

If `RETRIES >= 2`: mark `status: failed`, cancel the watchdog (see Case 4 for the command), report the log contents to the user, stop.

---

#### Case 2 — Log stall (process running, log size unchanged from last poll)

The process is alive but not making progress. This usually means it's waiting for input it will never receive, or it has entered a silent loop.

If `PREV_SIZE != -1` (not the first poll) and `LOG_SIZE == PREV_SIZE` and process is running:

1. Kill the process: `kill -TERM $PID && sleep 5 && kill -KILL $PID 2>/dev/null`
2. Check `RETRIES`. If `< 2`: retry launch with `--continue` flag to resume the session (see the skill's `SKILL.md` for the exact retry command).
3. If `RETRIES >= 2`: mark `status: failed`, cancel the watchdog (see Case 4), report to user with log tail.

---

#### Case 3 — Process exited, output missing

The process ran to completion but the expected `output_ref` file(s) don't exist.

1. Check the log tail for error messages.
2. If `RETRIES < 2`: retry with `--continue` (same as Case 2 retry).
3. If `RETRIES >= 2`: mark `status: failed`, cancel the watchdog (see Case 4), show user the log and suggest manual intervention.

---

#### Case 4 — Process exited, output present → verify

**If `scripts/delegate.sh` is present and the handoff document's `## Verification Expectations` section contains a fenced ```` ```bash ```` block**, run it mechanically instead of interpreting the section as prose:
```bash
bash scripts/delegate.sh verify TASK-N
```
This prints `STATE=PASS` or `STATE=FAIL` (with `EXITCODE=`) and the log path, and exits with the block's own exit code. Write handoff verification sections as an executable block (see Step 3) precisely so this is possible — it turns "completed only when verification passes" from a judgment call into something enforceable the same way regardless of which host tool is running this workflow.

**Otherwise**, run the verification commands from the handoff document by hand:
- File existence checks
- Content checks (grep for expected symbols/exports)
- Compile/test commands if applicable

**If verification passes:**
```markdown
- status: completed
- reviewed: <ISO timestamp>
- outcome: <one line — what was produced>
```
Check off sub-tasks: `- [x] <sub-task>`
Clear the `owner` field.

**Cancel the watchdog** — needed only on the manual/fallback launch path. When `scripts/delegate.sh` launched the task, its supervisor process cancels its own timer the instant the agent exits (see `helpers/scripts/delegate.sh`'s header comments) — there is nothing to do here. On the manual path, the watchdog subshell from Step 4 is still sleeping and would otherwise fire at the timeout, targeting a PID that may by then belong to an unrelated process (PID reuse):
```bash
WATCHDOG=$(cat ".delegate/tasks/TASK-N.watchdog.pid" 2>/dev/null)
kill "$WATCHDOG" 2>/dev/null
```
**Commit the TODO.md status update** in the main tree — `git add TODO.md && git commit -m "TASK-N: mark completed"` — so the tree is clean again before the next delegation. This is separate from merging the worktree's actual code changes: that merge is a deliberate, user-facing action (see `docs/usage.md`, "What gets created") and should not happen without the user's go-ahead, since it changes their current branch.

Report to user: what was built, where it lives, any caveats, and the merge/cleanup commands from `docs/usage.md` to bring the work into the current branch when ready.

**If verification fails:**
- Log what specifically failed.
- If `RETRIES < 2`: retry with `--continue` and a note in the prompt about what was wrong.
- If `RETRIES >= 2`: mark `status: failed`, **cancel the watchdog** (same command as above), report exact verification failures.

---

#### Case 5 — Process running, log growing normally

No action needed. Note the current log size and schedule the next poll.

---

### On timeout (watchdog fires or poll interval exceeded)

When `scripts/delegate.sh` launched the task, this already happened automatically — its supervisor races a timer against natural completion and sends SIGTERM then SIGKILL to the agent's real process tree (never an unrelated process that happens to reuse the PID). Nothing to do here but check `bash scripts/delegate.sh status TASK-N` for the outcome.

On the manual path:
```bash
PID=$(cat .delegate/tasks/TASK-N.pid)
WATCHDOG=$(cat .delegate/tasks/TASK-N.watchdog.pid 2>/dev/null)
kill -TERM "$PID" 2>/dev/null
sleep 30
kill -KILL "$PID" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null
```

Mark `status: timed_out`. Preserve the log and all files the agent wrote — partial progress is resumable with `--continue` in a future delegation. Report to user with a log tail and the list of any sub-tasks that were checked off before timeout.

---

## TODO.md Conventions (shared contract with all agents)

- One `## [TASK-N]` block per task — never delete, only update
- `owner` field prevents double-pickup — set on start, clear on completion/failure
- `retries` increments on every self-healing retry — never resets
- `depends_on` lists task IDs whose outputs this task needs — agents skip tasks with incomplete dependencies
- A task is `completed` only when verification expectations are explicitly confirmed, not just when the process exits
- Checkpoint at natural phase boundaries (after each file group, after each test run) by updating sub-task checkboxes
- **TODO.md has no lock of its own.** Two concurrent delegations running Step 1's manual computation at the same instant can read the same max task number and pick the same `TASK-N`, corrupting the ledger. `bash scripts/delegate.sh next-id` (see Step 1) closes this with an `mkdir`-based lock — portable to every platform this repo targets, including Windows, unlike `flock` — and self-heals a lock left behind by a crashed process after 30 seconds. Prefer it over the manual computation whenever `scripts/delegate.sh` is present. Without it: for parallel delegation from a single caller, assign task IDs sequentially *before* launching in parallel; for parallel callers, serialize the "pick next ID + append block" step some other way, or pre-allocate a block of IDs.
