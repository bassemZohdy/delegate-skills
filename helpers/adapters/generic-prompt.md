# Generic Delegation Prompt

A copy-paste prompt template for any AI assistant. Paste this into the system prompt, workspace instructions, or a slash command in your tool of choice (GitHub Copilot, Zed AI, Continue.dev, Cursor Composer, Windsurf Cascade, etc.).

Adjust the `<placeholder>` values for your project.

---

## System Prompt / Instructions Block

Paste this where your tool accepts persistent AI instructions:

```
## Task Delegation Protocol

When asked to delegate a coding task to a background agent CLI, follow these steps exactly.

### What you need before starting
- A git repository with at least one commit
- One of these agent CLIs on PATH: opencode, pi, mimo, hermes, kimi, codex, agy
- The project's bash/shell access

### Step 0 — Git Preflight
Run: `git status --short && git rev-parse HEAD && git branch --show-current`
- If the tree is dirty, ask the user whether to commit first or continue.
- Record the base SHA for the handoff document.

### Step 1 — Determine Task ID
Run: `grep -c '^## \[TASK-' TODO.md 2>/dev/null || echo 0`
Increment by 1. Use TASK-N (e.g. TASK-1) everywhere below.

### Step 2 — Create Worktree
Run: `git worktree add .opencode/worktrees/TASK-N -b <runtime>/TASK-N`

### Step 3 — Write TODO.md Entry
Append to TODO.md (create if absent):

```
## [TASK-N] <short title>
- status: in_progress
- owner: <runtime>/<ISO-8601>
- agent: <runtime>
- started: <ISO-8601>
- timeout: <seconds>
- worktree: .opencode/worktrees/TASK-N
- branch: <runtime>/TASK-N
- handoff: .opencode/tasks/TASK-N.md

### Sub-tasks
- [ ] <sub-task 1>

### Verification
<exact commands and files to check>
```

### Step 4 — Write Handoff Document
Create `.opencode/tasks/TASK-N.md` (agent's only context — 200–500 tokens):

```
# Task Handoff — TASK-N

## Task Description
<what to accomplish>

## Target Paths
<all files and directories involved>

## Worktree Path
.opencode/worktrees/TASK-N

## Sub-tasks
- [ ] <sub-task 1>

## Verification Expectations
<exact commands to run, files to check, expected outputs>

## Git State
- base_branch: <current branch>
- base_sha: <SHA from Step 0>
- agent_branch: <runtime>/TASK-N
```

### Step 5 — Launch Agent

If scripts/delegate.sh exists in the project:
```
bash scripts/delegate.sh <runtime> TASK-N <timeout-seconds>
```

Otherwise launch directly:

**opencode:**
```
nohup opencode run "Execute handoff." --file .opencode/tasks/TASK-N.md --dir .opencode/worktrees/TASK-N --dangerously-skip-permissions > .opencode/tasks/TASK-N.log 2>&1 &
echo $! > .opencode/tasks/TASK-N.pid
```

**pi:**
```
PROJECT_ROOT="$(pwd)"
cd .opencode/worktrees/TASK-N
nohup pi -p "@$PROJECT_ROOT/.opencode/tasks/TASK-N.md" "Execute handoff." --approve > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
```

**codex:**
```
export _CODEX_TASK_FILE="$(pwd)/.opencode/tasks/TASK-N.md"
export _CODEX_WORK_DIR="$(pwd)/.opencode/worktrees/TASK-N"
nohup bash -c 'codex exec -C "$_CODEX_WORK_DIR" -s danger-full-access --dangerously-bypass-approvals-and-sandbox - < "$_CODEX_TASK_FILE"' > .opencode/tasks/TASK-N.log 2>&1 &
echo $! > .opencode/tasks/TASK-N.pid
```

**hermes:**
```
PROJECT_ROOT="$(pwd)"
cd .opencode/worktrees/TASK-N
nohup hermes chat -q "Read $PROJECT_ROOT/.opencode/tasks/TASK-N.md and execute the task." --yolo --accept-hooks -Q > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
```

**kimi:**
```
PROJECT_ROOT="$(pwd)"
cd .opencode/worktrees/TASK-N
nohup kimi -p "Read $PROJECT_ROOT/.opencode/tasks/TASK-N.md and execute the task." -y > "$PROJECT_ROOT/.opencode/tasks/TASK-N.log" 2>&1 &
echo $! > "$PROJECT_ROOT/.opencode/tasks/TASK-N.pid"
```

**agy:**
```
nohup agy --print "Read $(pwd)/.opencode/tasks/TASK-N.md and execute." --add-dir .opencode/worktrees/TASK-N --dangerously-skip-permissions > .opencode/tasks/TASK-N.log 2>&1 &
echo $! > .opencode/tasks/TASK-N.pid
```

Set watchdog (replace PID and TIMEOUT):
```
(sleep <TIMEOUT> && kill -TERM <PID> 2>/dev/null && sleep 30 && kill -KILL <PID> 2>/dev/null) &
echo $! > .opencode/tasks/TASK-N.watchdog.pid
```

Tell the user: task ID, runtime, log path, worktree, expected timeout.

### Step 6 — Monitor and Self-Heal

Poll every ~20% of the timeout interval.

Check liveness: `kill -0 $(cat .opencode/tasks/TASK-N.pid) 2>/dev/null && echo running || echo done`
Read log: `tail -30 .opencode/tasks/TASK-N.log`
Check log size: `wc -c < .opencode/tasks/TASK-N.log`

Self-heal rules:
- If the process exits with a tiny log (< 500 bytes): read the error, fix the command, retry (max 2×)
- If the log stops growing between polls: the agent stalled — kill it and retry with --continue
- If the process exits cleanly but the output file is missing: retry with --continue
- If verification fails: retry with --continue and include notes on what failed
- If all retries exhausted: mark status: failed in TODO.md and report the log tail

### Step 7 — Complete

When the agent finishes and verification passes:
- Update TODO.md: `status: completed`, `reviewed: <ISO>`, `outcome: <one line>`
- Check off sub-tasks in TODO.md
- Report to user: what finished, what verification shows, merge command

Merge command:
```
git merge <runtime>/TASK-N
git worktree remove .opencode/worktrees/TASK-N
git branch -d <runtime>/TASK-N
```
```

---

## One-Shot Slash Command Version

For tools with custom slash commands (Continue.dev, Cursor, etc.), a shorter version that inlines the task:

```
You are delegating a coding task. Follow the delegation protocol:
1. Check git status. If dirty, ask the user.
2. Find the next TASK-N from TODO.md (or start at TASK-1).
3. Create worktree: `git worktree add .opencode/worktrees/TASK-N -b <runtime>/TASK-N`
4. Write .opencode/tasks/TASK-N.md as a 200-500 token cold-start briefing.
5. Launch: `bash scripts/delegate.sh <runtime> TASK-N 1800`
6. Report the task ID, log path, and expected completion time.

Task to delegate: {input}
Runtime to use: {runtime}
```

Replace `{input}` with the user's task description and `{runtime}` with the chosen CLI.

---

## Continue.dev Config

Add to `.continue/config.json`:

```json
{
  "slashCommands": [
    {
      "name": "delegate",
      "description": "Delegate a coding task to a background agent CLI",
      "prompt": "Follow the delegation protocol in the project's adapters/generic-prompt.md. Runtime: opencode. Task: {{{ input }}}"
    },
    {
      "name": "delegate-codex",
      "description": "Delegate to OpenAI Codex",
      "prompt": "Follow the delegation protocol in adapters/generic-prompt.md. Runtime: codex. Task: {{{ input }}}"
    }
  ]
}
```

The AI reads `adapters/generic-prompt.md` via the `@file` context provider, then executes the protocol using its terminal/bash tool.
