# delegate-skills

Skills that delegate coding tasks from your AI assistant to a background agent CLI, isolated in a git worktree, with structured handoff documents and self-healing monitoring.

Conforms to the [agentskills.io open standard](https://agentskills.io/specification) — install once in `~/.agents/skills/` and every compliant tool picks them up automatically. Also works natively in Claude Code via `~/.claude/skills/`.

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
| `delegate-to-any` | auto-selects best available | install any runtime below |
| `delegate-to-opencode` | [OpenCode](https://opencode.ai) | `npm install -g opencode-ai` |
| `delegate-to-codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | `npm install -g @openai/codex` |
| `delegate-to-pi` | [Pi](https://earendil.works) | `bun install -g @earendil-works/pi-coding-agent` |
| `delegate-to-mimo` | [MiMo](https://mimo.ai) | `npm install -g @mimo-ai/cli` |
| `delegate-to-hermes` | [Hermes Agent](https://hermes.agent) | see Hermes docs |
| `delegate-to-kimi` | [Kimi Code](https://kimi.ai) | see Kimi docs |
| `delegate-to-agy` | [Agy](https://agy.dev) | see Agy docs |

---

## Supported host tools

The skills conform to the [agentskills.io open standard](https://agentskills.io/specification). Install to `~/.agents/skills/` for maximum reach:

| Format | Install from | Works in |
|--------|-------------|----------|
| agentskills.io SKILL.md | `skills/` | OpenCode · OpenAI Codex · pi · Gemini CLI · Kimi · Claude Code · VS Code · Cursor · Windsurf · JetBrains · 40+ other tools |
| Hermes adapter | `helpers/hermes/` | Hermes Agent (needs explicit `~/.agents/skills/` config — see install guide) |
| Generic prompt + script | `helpers/adapters/` + `helpers/scripts/` | Any AI with bash/terminal access (Copilot, Zed AI, Continue.dev, …) |

> **`~/.agents/skills/` is the cross-tool standard.** OpenCode, Codex CLI, pi, Gemini CLI, and Kimi all scan it natively. Claude Code uses `~/.claude/skills/` — either install there too or symlink from `~/.agents/skills/`.

---

## Quick start

### Cross-tool install (recommended)

Installs to `~/.agents/skills/` — works natively in OpenCode, OpenAI Codex, pi, Gemini CLI, Kimi, and any [agentskills.io-compliant tool](https://agentskills.io/clients.md).

```bash
git clone https://github.com/bassem-io/delegate-skills.git
cd delegate-skills

# Copy — snapshot at install time
mkdir -p ~/.agents/skills
cp -r skills/shared ~/.agents/skills/
for skill in skills/delegate-to-*; do cp -r "$skill" ~/.agents/skills/; done

# Or symlink — stays in sync with the repo
REPO="$(pwd)"
mkdir -p ~/.agents/skills
ln -sf "$REPO/skills/shared" ~/.agents/skills/shared
for skill in skills/delegate-to-*; do
  ln -sf "$REPO/$skill" ~/.agents/skills/$(basename "$skill")
done
```

### Claude Code

Claude Code reads from `~/.claude/skills/`. Install there directly or symlink from the cross-tool location:

```bash
# Option A: install directly to ~/.claude/skills/
mkdir -p ~/.claude/skills
cp -r skills/shared ~/.claude/skills/
for skill in skills/delegate-to-*; do cp -r "$skill" ~/.claude/skills/; done

# Option B: symlink from the cross-tool location (keeps both in sync)
mkdir -p ~/.claude/skills
ln -sf ~/.agents/skills/shared ~/.claude/skills/shared
for skill in ~/.agents/skills/delegate-to-*; do
  ln -sf "$skill" ~/.claude/skills/$(basename "$skill")
done
```

Then in any Claude Code session:

```
/delegate-to-opencode add a User model with id, email, role, created_at to src/models/user.ts
```

Claude Code writes the handoff document, creates the worktree, launches opencode in the background, and polls until it's done.

### Hermes Agent

```bash
cp -r helpers/hermes/delegate-tasks ~/.hermes/skills/autonomous-ai-agents/
```

```
/delegate-tasks delegate to opencode: add a User model to src/models/user.ts
```

### Any other AI

Copy `helpers/adapters/generic-prompt.md` into your AI's system prompt or workspace instructions. It contains the full delegation protocol and all launch commands.

Or call the launcher script directly — after writing a handoff doc to `.opencode/tasks/TASK-1.md`:

```bash
bash helpers/scripts/delegate.sh opencode TASK-1 1800
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
│
├── skills/                          # installable skills — copy to ~/.claude/skills/ or ~/.agents/skills/
│   ├── shared/
│   │   └── workflow.md              # shared Steps 0–3 and 5 (referenced by all skills as ../shared/workflow.md)
│   ├── delegate-to-any/SKILL.md     # auto-router: picks best installed runtime
│   ├── delegate-to-opencode/SKILL.md
│   ├── delegate-to-codex/SKILL.md
│   ├── delegate-to-pi/SKILL.md
│   ├── delegate-to-mimo/SKILL.md
│   ├── delegate-to-hermes/SKILL.md
│   ├── delegate-to-kimi/SKILL.md
│   └── delegate-to-agy/SKILL.md
│
├── docs/                            # documentation only
│   ├── usage.md                     # usage guide, timeout tiers, model overrides
│   └── install.md                   # full install guide for every tool and format
│
├── helpers/                         # setup and configure helpers (not skills)
│   ├── scripts/
│   │   └── delegate.sh              # portable bash launcher (all 7 runtimes)
│   ├── adapters/
│   │   └── generic-prompt.md        # universal prompt for any AI tool
│   └── hermes/
│       └── delegate-tasks/SKILL.md  # hermes-native skill (hermes terminal() API format)
│
└── tests/                           # test suite
    ├── run-tests.sh
    └── test-structure.sh
```

---

## Documentation

- [`docs/install.md`](docs/install.md) — per-tool install guide, Hermes, Kimi, Continue.dev, generic setup
- [`docs/usage.md`](docs/usage.md) — invoking skills, model overrides, timeout tiers, merge workflow
- [`skills/shared/workflow.md`](skills/shared/workflow.md) — the shared workflow (Steps 0–5) all skills follow
- [`AGENTS.md`](AGENTS.md) — CLI differences table, known gotchas, conventions for agents editing this repo
- [`CHANGELOG.md`](CHANGELOG.md) — release history and notable changes

---

## Running tests

```bash
bash tests/run-tests.sh
```

Validates structure, frontmatter, workflow references, helper files, runtime coverage, **and** semantic regression checks that assert behavioral correctness (worktree isolation, real agent PID capture, watchdog teardown, Codex handoff framing). No external dependencies.

---

## License

MIT
