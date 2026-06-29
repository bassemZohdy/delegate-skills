# delegate-skills

Skills that delegate coding tasks from your AI assistant to a background agent CLI, isolated in a git worktree, with structured handoff documents and self-healing monitoring.

Works as native skills in **Claude Code** and **Hermes Agent**, and as a universal adapter for any AI tool with shell access.

---

## What it does

You describe a task. The skill:

1. Checks the git working tree for uncommitted changes
2. Creates an isolated branch and worktree for the agent
3. Writes a structured `TODO.md` ledger entry and a self-contained handoff document
4. Launches the agent CLI in the background with a timeout watchdog
5. Polls for progress, detects stalls, and retries automatically
6. Runs verification and reports back when done

The agent works independently while you keep collaborating with your AI assistant. Multiple agents can run in parallel — each in its own worktree.

---

## Supported runtimes

| Skill | Runtime | Quick install |
|-------|---------|---------------|
| `delegate-to-opencode` | [OpenCode](https://opencode.ai) | `npm install -g opencode-ai` |
| `delegate-to-codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | `npm install -g @openai/codex` |
| `delegate-to-pi` | [Pi](https://earendil.works) | `bun install -g @earendil-works/pi-coding-agent` |
| `delegate-to-mimo` | [MiMo](https://mimo.ai) | `npm install -g @mimo-ai/cli` |
| `delegate-to-hermes` | [Hermes Agent](https://hermes.agent) | see Hermes docs |
| `delegate-to-kimi` | [Kimi Code](https://kimi.ai) | see Kimi docs |
| `delegate-to-agy` | [Agy](https://agy.dev) | see Agy docs |

---

## Supported host tools

The skills come in three formats. Install the one that matches your tool:

| Format | Location | Works in |
|--------|----------|----------|
| Claude Code SKILL.md | `delegate-to-*/` | Claude Code CLI · VS Code · Cursor · Windsurf · JetBrains · Desktop · claude.ai/code |
| Hermes SKILL.md | `hermes-skills/` | Hermes Agent |
| Generic prompt + script | `adapters/` + `scripts/` | Any AI with bash/terminal access (Copilot, Zed AI, Continue.dev, …) |

> All Claude Code interfaces (CLI, VS Code extension, Cursor, Windsurf, JetBrains, Desktop app, claude.ai/code) share the same `~/.claude/skills/` directory — install once and every surface picks it up.

---

## Quick start

### Claude Code

```bash
# Clone and install globally
git clone https://github.com/bassem-io/delegate-skills.git
cd delegate-skills

# Install skills and shared docs (docs/ must be alongside the skill dirs)
mkdir -p ~/.claude/skills
cp -r docs ~/.claude/skills/
for skill in delegate-to-*; do cp -r "$skill" ~/.claude/skills/; done

# Or symlink to stay in sync
ln -sf "$(pwd)/docs" ~/.claude/skills/docs
for skill in delegate-to-*; do ln -sf "$(pwd)/$skill" ~/.claude/skills/$skill; done
```

Then in any Claude Code session:

```
/delegate-to-opencode add a User model with id, email, role, created_at to src/models/user.ts
```

Claude Code writes the handoff document, creates the worktree, launches opencode in the background, and polls until it's done.

### Hermes Agent

```bash
cp -r hermes-skills/delegate-tasks ~/.hermes/skills/autonomous-ai-agents/
```

```
/delegate-tasks delegate to opencode: add a User model to src/models/user.ts
```

### Any other AI

Copy `adapters/generic-prompt.md` into your AI's system prompt or workspace instructions. It contains the full delegation protocol and all launch commands.

Or call the script directly from any terminal — after writing a handoff doc to `.opencode/tasks/TASK-1.md`:

```bash
bash scripts/delegate.sh opencode TASK-1 1800
```

---

## How it works in detail

### Worktree isolation

Each task gets its own git branch (`<runtime>/TASK-N`) and a matching worktree at `.opencode/worktrees/TASK-N`. The agent writes only inside that worktree. When it finishes, you review and merge:

```bash
git merge opencode/TASK-1
git worktree remove .opencode/worktrees/TASK-1
git branch -d opencode/TASK-1
```

### Handoff documents

`.opencode/tasks/TASK-N.md` is the agent's entire context — it has no conversation history. The skill writes a structured briefing (task description, target paths, architectural constraints, sub-tasks, verification criteria, git state) and passes it via the runtime's file delivery mechanism:

| Runtime | Delivery method |
|---------|----------------|
| opencode, mimo | `--file path` flag |
| pi | `@path` positional argument |
| codex | stdin via `-` |
| hermes, kimi, agy | absolute path reference in the prompt |

### Self-healing

The skill monitors the agent and recovers from common failure modes:

| Symptom | Response |
|---------|----------|
| Process exits immediately, log < 500 bytes | Read error, fix command, retry (max 2×) |
| Process running, log not growing between polls | Kill, retry with `--continue` |
| Process exits cleanly, output missing | Retry with `--continue` |
| Verification fails after output is present | Retry with `--continue` + failure notes |
| All retries exhausted | Mark `failed`, report log tail |

### Timeout watchdog

Each launch gets a background watchdog: SIGTERM after the configured timeout, SIGKILL after 30 seconds if still alive. Timeout tiers:

| Tier | Task type | Timeout |
|------|-----------|---------|
| 1 | Single-file edit, simple fix | 10 min |
| 2 | New feature with tests, multi-file refactor | 30 min |
| 3 | Architecture change, large refactor | 2 hours |
| 4 | Multi-phase feature, cross-repo work | 8 hours |

---

## Repo structure

```
delegate-skills/
├── README.md
├── AGENTS.md                        # agent-facing conventions and CLI reference table
├── TODO.md                          # task ledger (append-only when skills are in use)
├── docs/
│   ├── workflow.md                  # shared Steps 0–3 and 5 (all Claude Code skills)
│   ├── usage.md                     # usage guide, timeout tiers, model overrides
│   └── install.md                   # full install guide for every tool and format
├── tests/
│   ├── run-tests.sh                 # test runner
│   └── test-structure.sh            # structure validation (139 checks)
│
│   Claude Code skills
├── delegate-to-opencode/SKILL.md
├── delegate-to-codex/SKILL.md
├── delegate-to-pi/SKILL.md
├── delegate-to-mimo/SKILL.md
├── delegate-to-hermes/SKILL.md
├── delegate-to-kimi/SKILL.md
├── delegate-to-agy/SKILL.md
│
│   Hermes-native skill
├── hermes-skills/
│   └── delegate-tasks/SKILL.md
│
│   Tool-agnostic adapters
├── scripts/
│   └── delegate.sh                  # portable bash launcher (all 7 runtimes)
└── adapters/
    └── generic-prompt.md            # universal prompt for any AI tool
```

---

## Documentation

- [`docs/install.md`](docs/install.md) — per-tool install guide, hermes install, kimi, Continue.dev, generic setup
- [`docs/usage.md`](docs/usage.md) — invoking skills, model overrides, timeout tiers, merge workflow
- [`docs/workflow.md`](docs/workflow.md) — the shared workflow (Steps 0–5) all skills follow
- [`AGENTS.md`](AGENTS.md) — CLI differences table, known gotchas, conventions for agents editing this repo

---

## Running tests

```bash
bash tests/run-tests.sh
```

Validates structure, frontmatter, workflow references, adapter files, and runtime coverage. No external dependencies.

---

## License

MIT
