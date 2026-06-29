---
name: delegate-tasks
description: "Delegate long-running coding tasks to a background agent CLI (opencode, pi, mimo, hermes, kimi, codex, agy) with git worktree isolation, structured handoff documents, and progress monitoring."
version: 1.0.0
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
terminal(command="grep -c '^## \\[TASK-' TODO.md 2>/dev/null || echo 0", workdir="<project>")
```

Increment by 1. Use `TASK-<N>` (e.g. `TASK-1`) throughout.

---

### Step 2 — Create Git Worktree

```
terminal(command="git worktree add .opencode/worktrees/TASK-<N> -b <runtime>/TASK-<N>", workdir="<project>")
```

---

### Step 3 — Write TODO.md Entry

Append to `TODO.md` (create it if absent):
```
terminal(command="cat >> TODO.md << 'ENTRY'\n\n## [TASK-<N>] <short title>\n- status: in_progress\n- owner: <runtime>/<timestamp>\n- agent: <runtime>\n- started: <ISO-8601>\n- timeout: <seconds>\n- worktree: .opencode/worktrees/TASK-<N>\n- branch: <runtime>/TASK-<N>\n- handoff: .opencode/tasks/TASK-<N>.md\n\n### Sub-tasks\n- [ ] <sub-task 1>\n\n### Verification\n<done criteria>\nENTRY", workdir="<project>")
```

---

### Step 4 — Write Handoff Document

Create `.opencode/tasks/TASK-<N>.md`. The agent has no conversation history — write as a cold-start briefing (200–500 tokens):

```
terminal(command="mkdir -p .opencode/tasks", workdir="<project>")
terminal(command="cat > .opencode/tasks/TASK-<N>.md << 'HANDOFF'\n# Task Handoff — TASK-<N>\n\n## Task Description\n<what to accomplish>\n\n## Target Paths\n<files and directories>\n\n## Worktree Path\n.opencode/worktrees/TASK-<N>\n\n## Sub-tasks\n- [ ] <sub-task>\n\n## Verification Expectations\n<commands to run, files to verify>\n\n## Git State\n- base_branch: <branch>\n- base_sha: <sha>\n- agent_branch: <runtime>/TASK-<N>\nHANDOFF", workdir="<project>")
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
terminal(command="nohup opencode run 'Execute handoff.' --file .opencode/tasks/TASK-<N>.md --dir .opencode/worktrees/TASK-<N> --dangerously-skip-permissions > .opencode/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

**pi:**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .opencode/worktrees/TASK-<N> && nohup pi -p '@'\"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.md\" 'Execute handoff.' --approve > \"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**hermes (self-delegate):**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .opencode/worktrees/TASK-<N> && nohup hermes chat -q 'Read '\"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.md\"' and execute.' --yolo --accept-hooks -Q > \"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**kimi:**
```
terminal(command="PROJECT_ROOT=$(pwd) && cd .opencode/worktrees/TASK-<N> && nohup kimi -p 'Read '\"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.md\"' and execute.' -y > \"$PROJECT_ROOT/.opencode/tasks/TASK-<N>.log\" 2>&1 & echo $!", workdir="<project>")
```

**codex:**
```
terminal(command="export _F=$(pwd)/.opencode/tasks/TASK-<N>.md _D=$(pwd)/.opencode/worktrees/TASK-<N> && nohup bash -c 'codex exec -C \"$_D\" -s danger-full-access --dangerously-bypass-approvals-and-sandbox - < \"$_F\"' > $(pwd)/.opencode/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

**mimo:**
```
terminal(command="nohup mimo run 'Execute handoff.' --file .opencode/tasks/TASK-<N>.md --dir .opencode/worktrees/TASK-<N> --dangerously-skip-permissions > .opencode/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

**agy:**
```
terminal(command="nohup agy --print 'Read $(pwd)/.opencode/tasks/TASK-<N>.md and execute.' --add-dir .opencode/worktrees/TASK-<N> --dangerously-skip-permissions > .opencode/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
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
terminal(command="tail -30 .opencode/tasks/TASK-<N>.log", workdir="<project>")
```

**Stall detection** — compare log size between polls:
```
terminal(command="wc -c < .opencode/tasks/TASK-<N>.log", workdir="<project>")
```

If the log stops growing, the agent stalled. Kill and retry with `--continue`:
```
terminal(command="kill <PID> && nohup opencode run 'Continue from where you left off.' --file .opencode/tasks/TASK-<N>.md --dir .opencode/worktrees/TASK-<N> --continue --dangerously-skip-permissions > .opencode/tasks/TASK-<N>.log 2>&1 & echo $!", workdir="<project>")
```

**On completion** — update TODO.md and report to user:
```
terminal(command="sed -i 's/status: in_progress/status: completed/' TODO.md", workdir="<project>")
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

Retry counter: track in `.opencode/tasks/TASK-<N>.retries` file and in the `retries:` field in TODO.md.

---

## Rules

1. Write handoff doc BEFORE launching — it is the agent's only context
2. Capture `PROJECT_ROOT=$(pwd)` BEFORE `cd`ing into the worktree — all absolute paths depend on it
3. Never expand handoff markdown into a shell variable — always pass as a file path
4. The `active_form` in the handoff tells you what mid-task progress looks like before the process exits
5. A task is `completed` only when verification passes, not when the process exits
6. For hermes self-delegation (hermes spawning hermes), use `--continue` in the child so sessions don't collide
