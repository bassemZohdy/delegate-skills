# AGENTS.md

## What this repo is

A collection of generic **skills** conforming to the [agentskills.io open standard](https://agentskills.io/specification) that delegate coding tasks to background agent CLIs with git worktree isolation. Eight installable skills (one auto-router, seven runtime-specific) plus helpers and adapters for tools without a native skill system.

Skills install to `~/.agents/skills/` (cross-tool interop path — OpenCode, Codex, pi, Gemini CLI, Kimi, and 40+ others) and/or `~/.claude/skills/` (Claude Code native path). The spec defines six official frontmatter fields: `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Claude Code adds `disable-model-invocation` and `argument-hint` as extensions; all other compliant tools silently ignore them.

| Skill | Runtime | Install |
|-------|---------|---------|
| `delegate-to-any` | auto-selects best available | — |
| `delegate-to-opencode` | `opencode` | `npm install -g opencode-ai` |
| `delegate-to-pi` | `pi` | `bun install -g @earendil-works/pi-coding-agent` |
| `delegate-to-mimo` | `mimo` | `npm install -g @mimo-ai/cli` |
| `delegate-to-hermes` | `hermes` | see Hermes Agent docs |
| `delegate-to-kimi` | `kimi` | see Kimi Code (Moonshot AI) docs |
| `delegate-to-codex` | `codex` | `npm install -g @openai/codex` |
| `delegate-to-agy` | `agy` | see Agy docs |

Not a traditional application — no build system, no CI.

## Directory layout

### `skills/` — installable skills

Generic SKILL.md files conforming to the agentskills.io spec. Install by copying to `~/.agents/skills/` (cross-tool standard) and/or `~/.claude/skills/` (Claude Code native). See `docs/install.md` for per-tool install instructions.

```
skills/
├── shared/
│   └── workflow.md          # Steps 0–3 and 5, shared by all skills via ../shared/workflow.md
├── delegate-to-any/
│   └── SKILL.md             # Step 4: scan all runtimes, select best, delegate
└── delegate-to-<runtime>/
    └── SKILL.md             # Step 4: detect, validate, launch, retry for one runtime
```

### `docs/` — documentation only

```
docs/
├── usage.md                 # human-facing usage guide
└── install.md               # install guide for all tools and formats
```

### `helpers/` — setup and configure helpers

Not installed as skills. Support files for configuring delegation in a project.

```
helpers/
├── scripts/
│   └── delegate.sh          # portable bash launcher — accepts <runtime> <task-id> [timeout]
├── adapters/
│   └── generic-prompt.md    # universal prompt template for any AI with bash/terminal access
└── hermes/
    └── delegate-tasks/
        └── SKILL.md         # hermes-native skill using terminal()/process() API
```

### `tests/` — test suite

```
tests/
├── run-tests.sh
└── test-structure.sh
```

Other top-level files:
- `.opencode/` — runtime artifacts (task logs, PID files, worktrees). **Do not edit by hand.**
- `TODO.md` — shared task ledger. Append-only; never delete or rewrite existing `## [TASK-N]` blocks.

## Key conventions

- Step order is a strict contract — Steps 0–5 must run in sequence. Skipping a step breaks cross-agent coordination.
- `TODO.md` `owner` field prevents double-pickup. Set on start, clear on completion/failure.
- A task is `completed` only after verification expectations pass, not when the process exits.
- Handoff documents (`.opencode/tasks/TASK-N.md`) are the agent's only context — write them as cold-start briefings, 200–500 tokens.
- **Never expand the handoff markdown into a shell variable** — special characters break cross-platform argument parsing. Use `--file` (opencode), `@path` (pi), stdin via `-` (codex), or absolute path reference in the prompt (hermes, kimi, agy).
- The `active_form` field in TODO.md is critical — it tells reviewing agents what mid-task progress looks like.
- For tools with no `--dir` flag (pi, hermes, kimi), capture `PROJECT_ROOT="$(pwd)"` **before** `cd`ing into the worktree so all `.opencode/tasks/*` paths stay correct.
- All skills reference the shared workflow via `../shared/workflow.md` (one level up from the skill directory, inside `skills/`).

## CLI differences that matter

| Feature | opencode | pi | mimo | hermes | kimi | codex | agy |
|---------|----------|----|------|--------|------|-------|-----|
| Run command | `opencode run "msg"` | `pi -p "msg"` | `mimo run "msg"` | `hermes chat -q "msg"` | `kimi -p "msg"` | `codex exec - < file` | `agy --print "msg"` |
| Handoff delivery | `--file path` | `@path` positional | `--file path` (check) | absolute path in prompt | absolute path in prompt | stdin (`-`) | absolute path in prompt |
| Working dir | `--dir path` | `cd` before (use PROJECT_ROOT) | `--dir path` (check) | `cd` before (use PROJECT_ROOT) | `cd` before (use PROJECT_ROOT) | `-C/--cd path` | `--add-dir path` |
| Skip perms | `--dangerously-skip-permissions` | `--approve` | `--dangerously-skip-permissions` (check) | `--yolo --accept-hooks` | `-y/--yolo` | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` |
| Continue | `--continue` | `--continue` | `--continue` | `--continue` | `-C/--continue` | `exec resume --last` | `--continue` |
| Model flag | `-m MODEL` | `--model MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | (config only) |
| Quiet/non-interactive | (default headless) | (default headless) | (default headless) | `-Q` | (default with `-p`) | (default with `exec`) | (default with `--print`) |

## Running tests

```bash
bash tests/run-tests.sh   # no external dependencies
```

## Known gotchas

- **opencode v0.15+**: known hang where the process doesn't exit after completing. The watchdog (SIGTERM + 30s SIGKILL) handles this.
- **pi path corruption**: `cd` changes the shell's cwd. Capture `PROJECT_ROOT="$(pwd)"` before `cd`ing and use absolute paths for all `.opencode/tasks/*` references.
- **hermes/kimi/agy — same cd issue**: same fix as pi. All three have no `--dir` flag.
- **mimo flags**: `--dangerously-skip-permissions`, `--dir`, and `--file` are checked at runtime via `mimo run --help`. Only flags confirmed present are used.
- **codex stdin**: uses `nohup bash -c '... < "$_CODEX_TASK_FILE"'` via exported env vars to avoid quoting issues with paths containing spaces.
- **codex no `--continue` flag**: resume uses `codex exec resume --last` (a subcommand, not a flag).
- **agy no model flag**: model selection is config-only. If user requests a model, instruct them to update Agy's config file instead.
- **hermes `--worktree` built-in flag**: hermes has its own worktree management. Do NOT pass `--worktree` — the skill manages worktrees itself to maintain cross-agent consistency in TODO.md.
- **Windows PATH**: after `npm install -g`, restart your terminal so the new binary is on the shell PATH that Claude Code uses.
