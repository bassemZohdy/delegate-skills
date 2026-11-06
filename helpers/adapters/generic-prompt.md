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
Run: `grep -h '^## \[TASK-' TODO.md TODO-ARCHIVE.md 2>/dev/null | sed -E 's/^## \[TASK-([0-9]+)\].*/\1/' | sort -n | tail -1`
Add 1 to the result (empty output → start at 1). Use TASK-N (e.g. TASK-1) everywhere below. Taking the MAX across both files matters: archived tasks live in `TODO-ARCHIVE.md`, and a count-based ID would collide with surviving tasks if any block was ever removed.

### Step 2 — Write TODO.md Entry
Append to TODO.md (create if absent):

```
## [TASK-N] <short title>
- status: in_progress
- owner: <runtime>/<ISO-8601>
- agent: <runtime>
- started: <ISO-8601>
- timeout: <seconds>
- worktree: .delegate/worktrees/TASK-N
- branch: <runtime>/TASK-N
- handoff: .delegate/tasks/TASK-N.md

### Sub-tasks
- [ ] <sub-task 1>

### Verification
<exact commands and files to check>
```

Commit it now, before creating the worktree: `git add TODO.md && git commit -m "TASK-N: add ledger entry"`. A worktree only sees *committed* history — creating it before this commit would leave the worktree with no trace of the task that owns it, and leave TODO.md dirty in the main tree, tripping Step 0's clean-tree check on the next delegation.

### Step 3 — Create Worktree
Run: `git worktree add .delegate/worktrees/TASK-N -b <runtime>/TASK-N`

### Step 4 — Write Handoff Document
Create `.delegate/tasks/TASK-N.md` (agent's only context — 200–500 tokens):

```
# Task Handoff — TASK-N

## Task Description
<what to accomplish>

## Target Paths
<all files and directories involved>

## Worktree Path
.delegate/worktrees/TASK-N

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

Locate the launcher (`delegate.sh`) once, in this order: `scripts/delegate.sh`
in the project; the copy bundled with any installed delegate skill (for example
`~/.agents/skills/delegate-to-any/scripts/delegate.sh` or
`~/.claude/skills/delegate-to-any/scripts/delegate.sh`); or
`helpers/scripts/delegate.sh` in a checkout of this repository. Below,
`$DELEGATE_SH` means that path. Always run it from the project root.

```
bash $DELEGATE_SH <runtime> TASK-N <timeout-seconds>          # add --model <id> only if asked
```

If no launcher is available, use the safe manual launch instructions from the
installed runtime skill (`skills/delegate-to-<runtime>/SKILL.md`). Keep its worktree verification, permission defaults and watchdog
behavior; do not improvise approval-bypass flags to make a blocked run succeed.

Supported helper runtimes: opencode, pi, mimo, hermes, kimi, codex and agy.
The default refuses unisolated launch. `DELEGATE_ALLOW_UNISOLATED=1` explicitly
permits editing the project root; `DELEGATE_ALLOW_UNSAFE_FLAGS=1` separately
opts into runtime approval/sandbox bypass. Neither may be set automatically.
Worktrees isolate code edits, not the operating system, credentials or network.

Tell the user: task ID, runtime, log path, worktree, expected timeout.

### Step 6 — Monitor and Self-Heal

Poll every ~20% of the timeout interval.

Check status: `bash $DELEGATE_SH status TASK-N` (prints `STATE=`, `EXITCODE=`, `LOG_SIZE=`, `RETRIES=`)
Read log: `tail -30 .delegate/tasks/TASK-N.log`
Without the launcher: `kill -0 $(cat .delegate/tasks/TASK-N.pid) 2>/dev/null && echo running || echo done`, and compare `wc -c < .delegate/tasks/TASK-N.log` between polls.

Self-heal rules (increment `.delegate/tasks/TASK-N.retries` before every retry; max 2):
- If the process exits with a tiny log (< 500 bytes; `STATE=LAUNCH_FAILED`): read the error, fix the command, relaunch
- If the log stops growing between polls (`STATE=STALLED`): `bash $DELEGATE_SH stop TASK-N`, then `bash $DELEGATE_SH <runtime> TASK-N <timeout> --continue`
- If the process exits cleanly but the output file is missing: retry with --continue
- If verification fails (`bash $DELEGATE_SH verify TASK-N` runs the handoff's fenced bash block): retry with --continue and include notes on what failed
- If all retries exhausted: mark status: failed in TODO.md and report the log tail

### Step 7 — Complete

When the agent finishes and verification passes:
- Update TODO.md: `status: completed`, `reviewed: <ISO>`, `outcome: <one line>`
- Check off sub-tasks in TODO.md
- Commit the update: `git add TODO.md && git commit -m "TASK-N: mark completed"` — keeps the main tree clean before the next delegation
- Report to user: what finished, what verification shows, merge command (do not merge automatically — it changes the user's current branch)

Merge command:
```
git merge <runtime>/TASK-N
git worktree remove .delegate/worktrees/TASK-N
git branch -d <runtime>/TASK-N
```
```

---

## One-Shot Slash Command Version

For tools with custom slash commands (Continue.dev, Cursor, etc.), a shorter version that inlines the task:

```
You are delegating a coding task. Follow the delegation protocol:
1. Check git status. If dirty, ask the user.
2. Get the next TASK-N: `bash $DELEGATE_SH next-id` (lock-protected), or max TASK number in TODO.md + 1.
3. Append the TODO.md entry and commit it: `git add TODO.md && git commit -m "TASK-N: add ledger entry"`.
4. Create worktree: `git worktree add .delegate/worktrees/TASK-N -b <runtime>/TASK-N`
5. Write .delegate/tasks/TASK-N.md as a 200-500 token cold-start briefing.
6. Launch: `bash $DELEGATE_SH <runtime> TASK-N 1800` (`$DELEGATE_SH`: the project's `scripts/delegate.sh`, or `scripts/delegate.sh` inside an installed delegate skill folder).
7. Report the task ID, log path, and expected completion time.

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
