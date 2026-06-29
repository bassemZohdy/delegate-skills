# Delegation Workflow

Shared workflow for all `delegate-to-*` skills. Each skill's `SKILL.md` references this document and adds its own Step 4 (runtime-specific launch logic).

---

## Step 0: Git Preflight

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

## Step 1: Create a Git Worktree

Parallel agents writing to the same working tree corrupt each other. Create an isolated checkout:

```bash
TASK_N=<next available N from TODO.md>
RUNTIME=<opencode|pi|mimo — whichever skill is running>
git worktree add .opencode/worktrees/TASK-$TASK_N -b $RUNTIME/TASK-$TASK_N
```

If the project is not a git repo, skip this step, log `worktree: none` in TODO.md, and proceed on the current working tree.

---

## Step 2: Update TODO.md

`TODO.md` lives at the project root and is the shared ledger for all agents. Create it if it doesn't exist. Append a new block — never edit or delete existing blocks.

```markdown
## [TASK-N] <short title>
- status: in_progress
- owner: <agent>/<ISO-timestamp>
- agent: <runtime> / <resolved model ID, or "default" if none specified>
- started: <ISO-8601>
- timeout: <chosen from timeout tiers — see docs/usage.md>
- worktree: .opencode/worktrees/TASK-N   # or "none"
- branch: <runtime>/TASK-N               # e.g. opencode/TASK-1, pi/TASK-2 — or "none"
- base_sha: <git rev-parse HEAD output>  # or "none"
- dirty_tree: false
- handoff: .opencode/tasks/TASK-N.md
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

---

## Step 3: Write the Handoff Document

Save to `.opencode/tasks/TASK-N.md`. This is the agent's only briefing — it has no conversation history. Write as if the reader is starting cold.

```markdown
# Task Handoff — TASK-N

## Task Description
<what to accomplish, in plain language>

## Target Paths
<all files and directories involved, one per line>

## Worktree Path
.opencode/worktrees/TASK-N   # or "(current directory — not a git repo)"

## Architectural Instructions
<design decisions, patterns, naming conventions, constraints the user specified>

## Sub-tasks
<mirror the sub-task list from TODO.md exactly>

## Active Form
<mirror the active_form from TODO.md — what mid-task progress looks like>

## Verification Expectations
<exact done criteria — test commands to run, outputs to check, files to verify>

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

### A. Check liveness

```bash
PID=$(cat .opencode/tasks/TASK-N.pid 2>/dev/null)
kill -0 "$PID" 2>/dev/null && echo "running" || echo "exited"
LOG_SIZE=$(wc -c < ".opencode/tasks/TASK-N.log" 2>/dev/null || echo 0)
PREV_SIZE=$(cat ".opencode/tasks/TASK-N.log.size" 2>/dev/null || echo -1)
echo $LOG_SIZE > ".opencode/tasks/TASK-N.log.size"
```

### B. Self-healing decision tree

Work through each case in order; stop at the first that applies.

---

#### Case 1 — Launch failure (process exited, log < 500 bytes)

The process quit almost immediately with no meaningful output. The most likely cause is a flag or path error at startup.

```bash
RETRIES=$(cat ".opencode/tasks/TASK-N.retries" 2>/dev/null || echo 0)
```

If `RETRIES < 2`:
1. Read the log to find the actual error message.
2. Adjust the launch command based on what the error says (e.g. wrong flag, bad path).
3. Increment retry counter: `echo $((RETRIES + 1)) > .opencode/tasks/TASK-N.retries`
4. Re-launch with the same command structure (Step 4), replacing the watchdog.
5. Update TODO.md: `retries: <new count>`, add a note under the block explaining what changed.

If `RETRIES >= 2`: mark `status: failed`, report the log contents to the user, stop.

---

#### Case 2 — Log stall (process running, log size unchanged from last poll)

The process is alive but not making progress. This usually means it's waiting for input it will never receive, or it has entered a silent loop.

If `PREV_SIZE != -1` (not the first poll) and `LOG_SIZE == PREV_SIZE` and process is running:

1. Kill the process: `kill -TERM $PID && sleep 5 && kill -KILL $PID 2>/dev/null`
2. Check `RETRIES`. If `< 2`: retry launch with `--continue` flag to resume the session (see the skill's `SKILL.md` for the exact retry command).
3. If `RETRIES >= 2`: mark `status: failed`, report to user with log tail.

---

#### Case 3 — Process exited, output missing

The process ran to completion but the expected `output_ref` file(s) don't exist.

1. Check the log tail for error messages.
2. If `RETRIES < 2`: retry with `--continue` (same as Case 2 retry).
3. If `RETRIES >= 2`: mark `status: failed`, show user the log and suggest manual intervention.

---

#### Case 4 — Process exited, output present → verify

Run the verification commands from the handoff document:
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
Report to user: what was built, where it lives, any caveats.

**If verification fails:**
- Log what specifically failed.
- If `RETRIES < 2`: retry with `--continue` and a note in the prompt about what was wrong.
- If `RETRIES >= 2`: mark `status: failed`, report exact verification failures.

---

#### Case 5 — Process running, log growing normally

No action needed. Note the current log size and schedule the next poll.

---

### On timeout (watchdog fires or poll interval exceeded)

```bash
PID=$(cat .opencode/tasks/TASK-N.pid)
WATCHDOG=$(cat .opencode/tasks/TASK-N.watchdog.pid 2>/dev/null)
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
