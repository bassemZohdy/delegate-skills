---
name: delegate-tasks
description: "Delegate long-running coding tasks to a background agent CLI (opencode, pi, mimo, hermes, kimi, codex, agy) with git worktree isolation, structured handoff documents, and progress monitoring."
version: 1.2.0
author: delegate-skills
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Coding-Agent, Delegation, Worktree, Background, OpenCode, Codex, Pi, Mimo, Kimi, Agy, Automation]
    related_skills: [coding-agent-clis, hermes-agent]
---

# Delegate Tasks

Delegate a coding task to a background agent CLI, isolated in a git worktree. The agent works independently while you stay responsive; you monitor progress and merge the result when done.

## When to Use

- Task will take more than a few minutes
- User wants multiple agents working in parallel on separate branches
- Need an audit trail via `TODO.md` ledger
- Protects the current working tree from in-progress changes

## Supported Runtimes

| Runtime | Command | Install |
|---------|---------|---------|
| `opencode` | `opencode run` | `npm install -g opencode-ai` |
| `pi` | `pi -p` | `bun install -g @earendil-works/pi-coding-agent` |
| `mimo` | `mimo run` | `npm install -g @mimo-ai/cli` |
| `hermes` | `hermes chat -q` | built-in |
| `kimi` | `kimi -p` | see Kimi Code docs |
| `codex` | `codex exec` | `npm install -g @openai/codex` |
| `agy` | `agy --print` | see Agy docs |

Detect availability before launching:
```
terminal(command="command -v opencode pi mimo hermes kimi codex agy 2>/dev/null", workdir="<project>")
```

---

## Full Workflow

### Step 0 — Git Preflight

```
terminal(command="git status --short && git rev-parse HEAD && git branch --show-current", workdir="<project>")
```

If the tree is dirty, ask the user whether to commit first or continue. Record `dirty_tree: true` in the TODO.md entry if continuing dirty.

Run existing tests to capture the baseline:
```
terminal(command="<project test command, e.g. npm test or pytest>", workdir="<project>", timeout=60)
```

---

### Step 1 — Determine Next Task Number

```
terminal(command="grep -ch '^## \\[TASK-' TODO.md TODO-ARCHIVE.md 2>/dev/null | awk '{s+=$1} END {print s+0}'", workdir="<project>")
```

Increment by 1. Use `TASK-<N>` (e.g. `TASK-1`) throughout. Checking `TODO-ARCHIVE.md` too matters if completed tasks have been archived out of `TODO.md` — otherwise a reused TASK-N would collide with archived history.

---

### Step 2 — Write TODO.md Entry

Append to `TODO.md` (create it if absent):
```
terminal(command="cat >> TODO.md << 'ENTRY'\n\n## [TASK-<N>] <short title>\n- status: in_progress\n- owner: <runtime>/<timestamp>\n- agent: <runtime>\n- started: <ISO-8601>\n- timeout: <seconds>\n- worktree: .delegate/worktrees/TASK-<N>\n- branch: <runtime>/TASK-<N>\n- handoff: .delegate/tasks/TASK-<N>.md\n\n### Sub-tasks\n- [ ] <sub-task 1>\n\n### Verification\n<done criteria>\nENTRY", workdir="<project>")
```

Commit it now, before creating the worktree:
```
terminal(command="git add TODO.md && git commit -m 'TASK-<N>: add ledger entry'", workdir="<project>")
```
A worktree only sees *committed* history — creating it before this commit leaves the worktree with no trace of the task that owns it, and leaves `TODO.md` dirty in the main tree, which trips the Step 0 clean-tree check on the next delegation.

---

### Step 3 — Create Git Worktree

```
terminal(command="git worktree add .delegate/worktrees/TASK-<N> -b <runtime>/TASK-<N>", workdir="<project>")
```

---

### Step 4 — Write Handoff Document

Create `.delegate/tasks/TASK-<N>.md`. The agent has no conversation history — write as a cold-start briefing (200–500 tokens):

```
terminal(command="mkdir -p .delegate/tasks", workdir="<project>")
terminal(command="cat > .delegate/tasks/TASK-<N>.md << 'HANDOFF'\n# Task Handoff — TASK-<N>\n\n## Task Description\n<what to accomplish>\n\n## Target Paths\n<files and directories>\n\n## Worktree Path\n.delegate/worktrees/TASK-<N>\n\n## Sub-tasks\n- [ ] <sub-task>\n\n## Verification Expectations\n<commands to run, files to verify>\n\n## Git State\n- base_branch: <branch>\n- base_sha: <sha>\n- agent_branch: <runtime>/TASK-<N>\nHANDOFF", workdir="<project>")
```

---

### Step 5 — Launch Agent via delegate.sh

Use the shared launcher script. It handles worktree reuse, the right launch command for the runtime, and the timeout watchdog:

```
terminal(command="bash scripts/delegate.sh <runtime> TASK-<N> <timeout-secs>", workdir="<project>")
```

Capture the output: `PID=`, `LOG=`, `WORK_DIR=`.

If `scripts/delegate.sh` is not present in the project, launch directly. See CLI patterns below.

#### Direct launch patterns (without delegate.sh)

**opencode:**
```
terminal(command="PROJECT_ROOT=$(pwd) && OPENCODE_AUTO=$(opencode run --help 2>&1 | grep -qo -- '--auto' && echo --auto || (opencode run --help 2>&1 | grep -qo -- '--dangerously-skip-permissions' && echo --dangerously-skip-permissions)) && nohup opencode run 'Execute handoff.' --file \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\" --dir \"$PROJECT_ROOT/.delegate/worktrees/TASK-<N>\" $OPENCODE_AUTO > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```
`--dir` points opencode's cwd at the worktree, so `--file` must be an absolute path — a relative one silently fails to resolve. The auto-approval flag name varies by version (`--auto` replaced `--dangerously-skip-permissions` as of opencode v1.17.x) — detect it rather than hardcoding.

**pi:**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .delegate/worktrees/TASK-<N> && nohup pi -p '@'\"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\" 'Execute handoff.' --approve > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**hermes (self-delegate):**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .delegate/worktrees/TASK-<N> && nohup hermes chat -q 'Read '\"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\"' and execute.' --yolo --accept-hooks -Q > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**kimi:**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .delegate/worktrees/TASK-<N> && nohup kimi -p 'Read '\"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\"' and execute.' -y > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**codex:**
```
terminal(command="export _F=$(pwd)/.delegate/tasks/TASK-<N>.md _D=$(pwd)/.delegate/worktrees/TASK-<N> && nohup bash -c '{ printf \"%s\\n\\n\" \"Execute the task described in the handoff document below. Follow all instructions in it exactly.\"; cat \"$_F\"; } | codex exec -C \"$_D\" -s danger-full-access --dangerously-bypass-approvals-and-sandbox -' > $(pwd)/.delegate/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

The `printf` framing is mandatory — piping the raw handoff risks Codex treating it as content to discuss rather than a task to execute.

**mimo:**
```
terminal(command="PROJECT_ROOT=$(pwd) && nohup mimo run 'Execute handoff.' --file \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\" --dir \"$PROJECT_ROOT/.delegate/worktrees/TASK-<N>\" --dangerously-skip-permissions > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```
Same absolute-path requirement as opencode above — `--dir` changes mimo's cwd, so `--file` must be absolute.

**agy:**
```
terminal(command="nohup agy --print 'Read $(pwd)/.delegate/tasks/TASK-<N>.md and execute.' --add-dir .delegate/worktrees/TASK-<N> --dangerously-skip-permissions > .delegate/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

Set a watchdog after any direct launch:
```
terminal(command="(sleep <timeout> && kill -TERM <PID> 2>/dev/null && sleep 30 && kill -KILL <PID> 2>/dev/null) & echo $!", workdir="<project>")
```

---

### Step 6 — Monitor Progress

Tell the user: task ID, runtime, log path, worktree path, timeout deadline.

Poll every ~20% of the timeout interval:

**Check liveness:**
```
terminal(command="kill -0 <PID> 2>/dev/null && echo running || echo done", workdir="<project>")
```

**Check log for progress:**
```
terminal(command="tail -30 .delegate/tasks/TASK-<N>.log", workdir="<project>")
```

**Stall detection** — compare log size between polls:
```
terminal(command="wc -c < .delegate/tasks/TASK-<N>.log", workdir="<project>")
```

If the log stops growing, the agent stalled. Kill and retry with `--continue` (reuse `$PROJECT_ROOT` and `$OPENCODE_AUTO` from the initial launch):
```
terminal(command="kill <PID> && nohup opencode run 'Continue from where you left off.' --file \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.md\" --dir \"$PROJECT_ROOT/.delegate/worktrees/TASK-<N>\" --continue $OPENCODE_AUTO > \"$PROJECT_ROOT/.delegate/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**On completion** — update TODO.md, commit it, and report to user:
```
terminal(command="sed -i 's/status: in_progress/status: completed/' TODO.md && git add TODO.md && git commit -m 'TASK-<N>: mark completed'", workdir="<project>")
```
Committing keeps the main tree clean before the next delegation. Merging the worktree's actual code changes into the current branch is a separate, deliberate step — report the merge command to the user rather than running it automatically, since it changes their current branch:
```
terminal(command="git merge <runtime>/TASK-<N> && git worktree remove .delegate/worktrees/TASK-<N> && git branch -d <runtime>/TASK-<N>", workdir="<project>")
```

---

## Self-Healing Decision Tree

| Symptom | Action |
|---------|--------|
| Process exits, log < 500 bytes | Read error, adjust command, retry (max 2×) |
| Process running, log not growing | Kill + retry with `--continue` |
| Process exits cleanly, no output | Retry with `--continue` |
| Verification fails after output | Retry with `--continue` + notes on what failed |
| All retries exhausted | Mark `failed`, report log tail to user |

Retry counter: track in `.delegate/tasks/TASK-<N>.retries` file and in the `retries:` field in TODO.md.

---

## Rules

1. Commit the TODO.md ledger entry BEFORE creating the worktree — worktrees only see committed history, so a worktree created first would never see the entry, and an uncommitted TODO.md blocks the next delegation's clean-tree check
2. Write handoff doc BEFORE launching — it is the agent's only context
3. Capture `PROJECT_ROOT=$(pwd)` BEFORE `cd`ing into the worktree — all absolute paths depend on it
4. Never expand handoff markdown into a shell variable — always pass as a file path
5. The `active_form` in the handoff tells you what mid-task progress looks like before the process exits
6. A task is `completed` only when verification passes, not when the process exits
7. For hermes self-delegation (hermes spawning hermes), use `--continue` in the child so sessions don't collide
