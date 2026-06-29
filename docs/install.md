# Installation Guide

## What these files are

This repository contains **skill files** — markdown files with YAML frontmatter that AI tools load at startup to extend their capability. When installed, they add `/delegate-to-<runtime>` commands (or equivalent) to your AI assistant.

The files come in three formats:

| Format | Location in this repo | For which tools |
|--------|----------------------|-----------------|
| Claude Code SKILL.md | `delegate-to-*/SKILL.md` | Claude Code CLI, VS Code/Cursor/Windsurf/JetBrains/Desktop extensions, claude.ai/code |
| Hermes SKILL.md | `hermes-skills/*/SKILL.md` | Hermes Agent |
| Generic prompt | `adapters/generic-prompt.md` | Any AI with bash/terminal access |
| Core script | `scripts/delegate.sh` | Called by any AI or directly from a terminal |

---

## Concept: where each tool looks for skills

Each AI tool has a directory where it reads skills from. You install these files by copying them to the right place for your tool.

| Tool | Skill directory | Invocation |
|------|----------------|------------|
| Claude Code CLI | `~/.claude/skills/` (global) or `.claude/skills/` (project) | `/delegate-to-opencode` |
| Claude Code — VS Code extension | Same as CLI (`~/.claude/skills/`) | `/delegate-to-opencode` |
| Claude Code — Cursor extension | Same as CLI (`~/.claude/skills/`) | `/delegate-to-opencode` |
| Claude Code — Windsurf extension | Same as CLI (`~/.claude/skills/`) | `/delegate-to-opencode` |
| Claude Code — JetBrains plugin | Same as CLI (`~/.claude/skills/`) | `/delegate-to-opencode` |
| Claude Code Desktop | Same as CLI (`~/.claude/skills/`) | `/delegate-to-opencode` |
| claude.ai/code | Synced from CLI config | `/delegate-to-opencode` |
| Hermes Agent | `~/.hermes/skills/` or `%LOCALAPPDATA%/hermes/skills/` | `/delegate-tasks` |
| Kimi Code | `~/.kimi-code/skills/` or via `--skills-dir <path>` | varies by skill name |
| Any other AI | No skill directory — use `adapters/generic-prompt.md` | paste into chat / system prompt |

> **One install covers many surfaces.** All Claude Code interfaces (CLI, VS Code, Cursor, Windsurf, JetBrains, Desktop) share the same `~/.claude/skills/` directory. Install once and all surfaces see the skills immediately.

---

## Claude Code skills

### Required layout

Each `SKILL.md` references `../docs/workflow.md`. The `docs/` folder must be installed **alongside** the skill folders, one level up:

```
<skills-root>/
├── docs/
│   ├── workflow.md
│   ├── usage.md
│   └── install.md
├── delegate-to-opencode/
│   └── SKILL.md
├── delegate-to-pi/
│   └── SKILL.md
└── ...
```

Global install target: `~/.claude/skills/`
Project install target: `.claude/skills/` (at the project root)

### Installing

Copy or symlink the directories. On any platform with a POSIX shell (macOS, Linux, WSL, Git Bash on Windows):

```bash
# Copy — snapshot at install time
SKILLS=~/.claude/skills
mkdir -p "$SKILLS"
cp -r docs "$SKILLS/"
for skill in delegate-to-opencode delegate-to-pi delegate-to-mimo \
             delegate-to-hermes delegate-to-kimi delegate-to-codex delegate-to-agy; do
  cp -r "$skill" "$SKILLS/"
done

# Symlink — stays in sync with the repo
REPO="$(pwd)"   # run from the repo root
SKILLS=~/.claude/skills
mkdir -p "$SKILLS"
ln -sf "$REPO/docs" "$SKILLS/docs"
for skill in delegate-to-opencode delegate-to-pi delegate-to-mimo \
             delegate-to-hermes delegate-to-kimi delegate-to-codex delegate-to-agy; do
  ln -sf "$REPO/$skill" "$SKILLS/$skill"
done
```

On Windows without a POSIX shell, use PowerShell — copy and junction-link are equivalent to the above. The concept is the same: place `docs/` and `delegate-to-*/` under the same parent directory.

### Verifying

In any Claude Code session, type `/delegate` — all installed skills appear in autocomplete. Or check the files directly:

```bash
ls ~/.claude/skills/delegate-to-opencode/SKILL.md
ls ~/.claude/skills/docs/workflow.md
```

### Per-surface notes

**VS Code / Cursor / Windsurf / JetBrains** — install the Claude Code extension for your editor, then the `~/.claude/skills/` global install is automatically available. No additional configuration.

**MiniMax Code, other VS Code forks** — install the Claude Code extension via VSIX if it isn't in the fork's marketplace.

**claude.ai/code (web)** — runs `claude` CLI under the hood. The `~/.claude/skills/` install syncs automatically; refresh the browser if skills don't appear.

---

## Hermes skills

### Required layout

```
<hermes-skills-root>/
└── delegate-tasks/
    └── SKILL.md
```

Hermes's local skills directory (where it reads user-defined skills from):

```bash
hermes skills list   # shows installed skills and their sources
```

Look for entries marked `local` — those come from the user skills directory. Typical paths:

| Platform | Path |
|----------|------|
| macOS / Linux | `~/.hermes/skills/` |
| Windows | `%LOCALAPPDATA%\hermes\skills\` |

### Installing

```bash
HERMES_SKILLS=~/.hermes/skills   # adjust to your platform path
mkdir -p "$HERMES_SKILLS/autonomous-ai-agents"
cp -r hermes-skills/delegate-tasks "$HERMES_SKILLS/autonomous-ai-agents/"
```

Verify:
```bash
hermes skills list   # delegate-tasks should appear as local/enabled
```

### Invoking

In a Hermes chat session:
```
/delegate-tasks delegate to opencode: add a User model to src/models/user.ts
```

Hermes reads the skill and runs the delegation workflow using its `terminal()` and `process()` tool API.

---

## Kimi Code skills

Kimi's `--skills-dir` flag loads skills from a specified directory. Pass it at invocation time or set a default in `~/.kimi-code/config.toml`.

```bash
kimi --skills-dir /path/to/delegate-skills/kimi-skills
```

To auto-load without the flag, check whether Kimi auto-discovers a `skills/` subdirectory in `~/.kimi-code/` or a project-local `.kimi-code/skills/` directory, and place the skill files there.

> Kimi's native skill format is not yet documented publicly. The Claude Code SKILL.md format may be partially compatible — test by running `kimi --skills-dir delegate-to-opencode` and observing whether `/delegate-to-opencode` appears as a command. The hermes-format skills (`hermes-skills/`) are an alternative since they use the same SKILL.md format but with different metadata.

---

## Any other AI tool

For tools without a skill system (GitHub Copilot, Zed AI, Continue.dev, any chat AI):

**Option 1 — Paste the generic prompt:** Copy `adapters/generic-prompt.md` into the tool's system prompt, workspace instructions, or a custom slash command definition. The AI then follows the protocol using its own bash/terminal tool.

**Option 2 — Call the script directly:** Any AI with shell access can run:
```bash
bash /path/to/delegate-skills/scripts/delegate.sh <runtime> TASK-N [timeout-seconds]
```
after writing the handoff document to `.opencode/tasks/TASK-N.md`.

**Option 3 — Use Claude Code CLI alongside:** Open a terminal in your editor, run `claude`, and invoke `/delegate-to-<runtime>`. The delegation runs in the background; you return to your editor. Works in Zed, Vim, Emacs, or any editor with a terminal pane.

See `adapters/generic-prompt.md` for Continue.dev slash command config and a one-shot slash command template.

---

## Installing the core script

`scripts/delegate.sh` is a standalone bash script. Install it in any project that needs tool-agnostic delegation:

```bash
mkdir -p .claude/scripts
cp /path/to/delegate-skills/scripts/delegate.sh .claude/scripts/delegate.sh
chmod +x .claude/scripts/delegate.sh
```

Or symlink it so it stays in sync:
```bash
ln -sf /path/to/delegate-skills/scripts/delegate.sh scripts/delegate.sh
```

Any AI (hermes, kimi, copilot, cursor, etc.) can then call it via their terminal/bash tool.

---

## Uninstalling

Remove the directories you installed. For Claude Code:
```bash
rm -rf ~/.claude/skills/delegate-to-opencode   # remove one skill
rm -rf ~/.claude/skills/docs                   # remove shared docs (after all skills are removed)
```

For Hermes:
```bash
hermes skills uninstall delegate-tasks   # if installed via hermes registry
# or remove manually:
rm -rf ~/.hermes/skills/autonomous-ai-agents/delegate-tasks
```

---

## Troubleshooting

**Claude Code: skill not in autocomplete**
Confirm the file exists: `ls ~/.claude/skills/delegate-to-opencode/SKILL.md`
Restart the Claude Code session — skills load at startup.
Check that the first line of SKILL.md is exactly `---`.

**`missing_runtime` error**
The agent CLI (opencode, pi, etc.) isn't on PATH. Install it (see `usage.md`) and restart your terminal.

**Skill can't find `../docs/workflow.md`**
The `docs/` folder wasn't installed alongside the skill folders. Re-install and include `docs/`.

**Worktree creation fails**
Requires a git repo with at least one commit: `git init && git commit --allow-empty -m "init"`

**`scripts/delegate.sh` exits with "Runtime not found"**
The chosen agent CLI is not on PATH. Install it or verify with `command -v <runtime>`.

**Hermes skill not appearing**
Run `hermes skills list` to confirm the file was found. The skill directory path must match what hermes reads — check with `hermes skills list --verbose` if available.
