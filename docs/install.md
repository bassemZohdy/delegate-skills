# Installation Guide

## What these files are

This repository contains **skill files** conforming to the [agentskills.io open standard](https://agentskills.io/specification) (Apache 2.0 / CC-BY-4.0). When installed, they add `/delegate-to-<runtime>` commands (or equivalent slash commands) to your AI assistant.

| Format | Location in this repo | For which tools |
|--------|----------------------|-----------------|
| agentskills.io SKILL.md | `skills/delegate-to-*/` | Any tool supporting `~/.agents/skills/` or `~/.claude/skills/` |
| Hermes adapter | `helpers/hermes/delegate-tasks/` | Hermes Agent (uses its own skill format) |
| Generic prompt + script | `helpers/adapters/` + `helpers/scripts/` | Any AI with bash/terminal access |

---

## The cross-tool install path: `~/.agents/skills/`

`~/.agents/skills/` is the community-standard interoperability path defined by the agentskills.io spec. Tools that scan it natively:

| Tool | Native `~/.agents/skills/` support | Notes |
|------|------------------------------------|-------|
| OpenAI Codex CLI | ✅ Primary user-level path | Also scans ancestor `.agents/skills/` dirs |
| OpenCode | ✅ Scanned alongside `~/.claude/skills/` | Scans both at startup |
| pi | ✅ Scanned alongside `~/.pi/agent/skills/` | Also supports `--skill <path>` flag |
| Gemini CLI | ✅ Takes precedence over `~/.gemini/skills/` | |
| Kimi Code CLI | ✅ "Generic group" path | Also scans `~/.config/agents/skills/` |
| Claude Code | ⚠️ Uses `~/.claude/skills/` primarily | May vary by version; install to both to be safe |
| Hermes Agent | ⚠️ Requires explicit config | Add `~/.agents/skills` to `external_dirs` in `~/.hermes/config.yaml` |
| mimo | ❓ Not confirmed | Install directly via mimo's own skills path |
| agy | ❓ Not confirmed | Install directly via agy's own skills path |

### Required layout

Each `SKILL.md` references `../shared/workflow.md`. The `shared/` folder must be installed **alongside** the skill folders, one level up:

```
<skills-root>/                  ← ~/.agents/skills/ or ~/.claude/skills/
├── shared/
│   └── workflow.md
├── delegate-to-any/
│   └── SKILL.md
├── delegate-to-opencode/
│   └── SKILL.md
└── ...
```

### Installing to `~/.agents/skills/`

On macOS, Linux, WSL, or Git Bash on Windows:

```bash
# Copy — snapshot at install time
mkdir -p ~/.agents/skills
cp -r skills/shared ~/.agents/skills/
for skill in skills/delegate-to-*; do
  cp -r "$skill" ~/.agents/skills/
done

# Symlink — stays in sync with the repo (run from repo root)
REPO="$(pwd)"
mkdir -p ~/.agents/skills
ln -sf "$REPO/skills/shared" ~/.agents/skills/shared
for skill in skills/delegate-to-*; do
  ln -sf "$REPO/$skill" ~/.agents/skills/$(basename "$skill")
done
```

### Verifying

```bash
ls ~/.agents/skills/delegate-to-opencode/SKILL.md
ls ~/.agents/skills/shared/workflow.md
```

Then invoke in any supported tool:
```
/delegate-to-opencode add a User model to src/models/user.ts
```

---

## Claude Code

Claude Code reads from `~/.claude/skills/`. Install there directly, or symlink from the cross-tool location:

```bash
# Option A: install directly
mkdir -p ~/.claude/skills
cp -r skills/shared ~/.claude/skills/
for skill in skills/delegate-to-*; do
  cp -r "$skill" ~/.claude/skills/
done

# Option B: symlink from ~/.agents/skills/ (keeps both locations in sync)
mkdir -p ~/.claude/skills
ln -sf ~/.agents/skills/shared ~/.claude/skills/shared
for skill in ~/.agents/skills/delegate-to-*; do
  ln -sf "$skill" ~/.claude/skills/$(basename "$skill")
done
```

**Supported Claude Code surfaces** — all use `~/.claude/skills/`, installed once:

| Surface | Notes |
|---------|-------|
| Claude Code CLI | Global `~/.claude/skills/` or project `.claude/skills/` |
| VS Code extension | Same as CLI |
| Cursor extension | Same as CLI |
| Windsurf extension | Same as CLI |
| JetBrains plugin | Same as CLI |
| Claude Code Desktop | Same as CLI |
| claude.ai/code | Syncs from CLI config; refresh browser if skills don't appear |

**VS Code forks (MiniMax Code, etc.)** — install the Claude Code extension via VSIX if it isn't in the fork's marketplace.

### Verifying

In any Claude Code session, type `/delegate` — all installed skills appear in autocomplete. Or check:

```bash
ls ~/.claude/skills/delegate-to-opencode/SKILL.md
ls ~/.claude/skills/shared/workflow.md
```

---

## OpenAI Codex CLI

Codex uses `~/.agents/skills/` as its primary user-level path. Once installed there (see above), skills load automatically. Codex also scans `.agents/skills/` in every ancestor directory up to the repo root for project-level skills.

No additional configuration needed.

---

## pi

pi scans `~/.agents/skills/` automatically alongside `~/.pi/agent/skills/`. Once the cross-tool install is done, skills are available immediately. You can also pass `--skill <path>` at invocation or declare skills in `package.json` under `pi.skills`.

---

## Gemini CLI

Gemini CLI scans `~/.agents/skills/` at the user scope (takes precedence over `~/.gemini/skills/`). Cross-tool install is all that's needed.

---

## Kimi Code CLI

Kimi scans `~/.agents/skills/` and `~/.config/agents/skills/` in its "generic group" alongside Kimi-specific paths. Cross-tool install works. Skills are also picked up from a project-local `.agents/skills/` directory.

---

## Hermes Agent

Hermes does not scan `~/.agents/skills/` by default. Add it to `~/.hermes/config.yaml`:

```yaml
skills:
  external_dirs:
    - ~/.agents/skills
```

Then restart Hermes. Verify with `hermes skills list`.

Alternatively, use the Hermes-native adapter which uses Hermes's own `terminal()` API format:

```bash
HERMES_SKILLS=~/.hermes/skills   # adjust to your platform path
mkdir -p "$HERMES_SKILLS/autonomous-ai-agents"
cp -r helpers/hermes/delegate-tasks "$HERMES_SKILLS/autonomous-ai-agents/"
```

Verify:
```bash
hermes skills list   # delegate-tasks should appear as local/enabled
```

Invoke:
```
/delegate-tasks delegate to opencode: add a User model to src/models/user.ts
```

| Platform | Hermes skills path |
|----------|-------------------|
| macOS / Linux | `~/.hermes/skills/` |
| Windows | `%LOCALAPPDATA%\hermes\skills\` |

---

## Any other AI tool

For tools without a skill system (GitHub Copilot, Zed AI, Continue.dev, any chat AI):

**Option 1 — Paste the generic prompt:** Copy `helpers/adapters/generic-prompt.md` into the tool's system prompt, workspace instructions, or a custom slash command definition.

**Option 2 — Call the script directly:**
```bash
bash /path/to/delegate-skills/helpers/scripts/delegate.sh <runtime> TASK-N [timeout-seconds]
```
after writing the handoff document to `.opencode/tasks/TASK-N.md`.

**Option 3 — Use Claude Code CLI alongside:** Open a terminal in your editor, run `claude`, and invoke `/delegate-to-<runtime>`. Works in Zed, Vim, Emacs, or any editor with a terminal pane.

See `helpers/adapters/generic-prompt.md` for Continue.dev slash command config and a one-shot slash command template.

---

## Installing the launcher script

`helpers/scripts/delegate.sh` is a standalone bash script. Copy it into any project:

```bash
mkdir -p scripts
cp /path/to/delegate-skills/helpers/scripts/delegate.sh scripts/delegate.sh
chmod +x scripts/delegate.sh
```

Or symlink:
```bash
ln -sf /path/to/delegate-skills/helpers/scripts/delegate.sh scripts/delegate.sh
```

---

## Uninstalling

```bash
# From ~/.agents/skills/
rm -rf ~/.agents/skills/shared
rm -rf ~/.agents/skills/delegate-to-any
rm -rf ~/.agents/skills/delegate-to-opencode   # repeat for each skill

# From ~/.claude/skills/
rm -rf ~/.claude/skills/shared
rm -rf ~/.claude/skills/delegate-to-opencode   # repeat for each skill

# Hermes native adapter
rm -rf ~/.hermes/skills/autonomous-ai-agents/delegate-tasks
```

---

## Troubleshooting

**Skill not in autocomplete**
Confirm the file exists (`ls ~/.agents/skills/delegate-to-opencode/SKILL.md`) and restart the AI session — skills load at startup.

**`missing_runtime` error**
The agent CLI isn't on PATH. Install it (see `docs/usage.md`) and restart your terminal.

**Skill can't find `../shared/workflow.md`**
The `shared/` folder wasn't installed alongside the skill folders. Re-run the install commands and include `skills/shared/`.

**Worktree creation fails**
Requires a git repo with at least one commit: `git init && git commit --allow-empty -m "init"`

**Hermes skill not appearing**
Run `hermes skills list`. Check that `external_dirs` in `~/.hermes/config.yaml` points to the correct path and that Hermes was restarted after the config change.

**`helpers/scripts/delegate.sh` exits with "Runtime not found"**
The chosen agent CLI is not on PATH. Verify with `command -v <runtime>`.
