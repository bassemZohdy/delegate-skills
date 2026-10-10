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

Not a traditional application. Bash structure, behavior and safety tests run in GitHub Actions on Ubuntu and Windows Git Bash.

## Directory layout

### `skills/` — installable skills

Generic SKILL.md files conforming to the agentskills.io spec. Install by copying to `~/.agents/skills/` (cross-tool standard) and/or `~/.claude/skills/` (Claude Code native). See `docs/install.md` for per-tool install instructions.

```
skills/
├── shared/
│   └── workflow.md          # canonical source for Steps 0–3 and 5 — maintainer-only, not distributed
├── delegate-to-any/
│   ├── SKILL.md             # Step 4: scan all runtimes, select best, delegate
│   └── workflow.md          # copy of skills/shared/workflow.md
└── delegate-to-<runtime>/
    ├── SKILL.md             # Step 4: detect, validate, launch, retry for one runtime
    └── workflow.md          # copy of skills/shared/workflow.md
```

Every skill folder is **self-contained**: it carries its own `workflow.md` copy and
its `SKILL.md` references it as a local path (`workflow.md`, never `../shared/workflow.md`).
This matters because single-skill installers (`npx skills add owner/repo --skill
delegate-to-kimi`, the [skills.sh](https://skills.sh) CLI) fetch only the named
subdirectory — a sibling `../shared/` reference would 404. `skills/shared/` has no
`SKILL.md` of its own, so skill scanners ignore it entirely; it exists only so a
maintainer edits the workflow in one place and syncs it out to the 8 copies:

```bash
bash helpers/scripts/sync-skills.sh
bash helpers/scripts/sync-skills.sh --check
```

`tests/test-structure.sh` enforces that every copy stays byte-identical to the
canonical source, and that `.agents/skills/` mirrors `skills/` exactly.

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
├── test-structure.sh            # structure/text-pattern assertions
├── test-behavior.sh             # behavioral tests — executes delegate.sh for real
└── fixtures/
    └── mock-bin/                # mock CLI binaries used by test-behavior.sh
```

Two-layer approach: structure tests grep-match frontmatter and text patterns (420 assertions); behavior tests actually *execute* `delegate.sh` against mocks in isolated sandboxes (16 test cases verifying real process/filesystem state).

Other top-level files:
- `.delegate/` — runtime artifacts (task logs, PID files, worktrees). **Do not edit by hand.**
- `TODO.md` — shared task ledger. Append-only; never delete or rewrite existing `## [TASK-N]` blocks.

## Key conventions

- Step order is a strict contract — Steps 0–5 must run in sequence. Skipping a step breaks cross-agent coordination.
- `TODO.md` `owner` field prevents double-pickup. Set on start, clear on completion/failure.
- A task is `completed` only after verification expectations pass, not when the process exits.
- Handoff documents (`.delegate/tasks/TASK-N.md`) are the agent's only context — write them as cold-start briefings, 200–500 tokens.
- **Never expand the handoff markdown into a shell variable** — special characters break cross-platform argument parsing. Use `--file` (opencode), `@path` (pi), stdin via `-` (codex), or absolute path reference in the prompt (hermes, kimi, agy).
- The `active_form` field in TODO.md is critical — it tells reviewing agents what mid-task progress looks like.
- For tools with no `--dir` flag (pi, hermes, kimi), capture `PROJECT_ROOT="$(pwd)"` **before** `cd`ing into the worktree so all `.delegate/tasks/*` paths stay correct.
- All skills reference their own local `workflow.md` copy (never `../shared/workflow.md` — that breaks single-folder installs). Edit `skills/shared/workflow.md` and re-sync copies; don't hand-edit a distributed copy directly.

## CLI differences that matter

| Feature | opencode | pi | mimo | hermes | kimi | codex | agy |
|---------|----------|----|------|--------|------|-------|-----|
| Run command | `opencode run "msg"` | `pi -p "msg"` | `mimo run "msg"` | `hermes chat -q "msg"` | `kimi -p "msg"` | `printf framing \| codex exec -` | `agy --print "msg"` |
| Handoff delivery | `--file path` | `@path` positional | `--file path` (check) | absolute path in prompt | absolute path in prompt | stdin (`-`) | absolute path in prompt |
| Working dir | `--dir path` | `cd` before (use PROJECT_ROOT) | `--dir path` (check) | `cd` before (use PROJECT_ROOT) | `cd` before (use PROJECT_ROOT) | `-C/--cd path` | `--add-dir path` |
| Skip perms | `--dangerously-skip-permissions` | `--approve` | `--dangerously-skip-permissions` (check) | `--yolo --accept-hooks` | `-y/--yolo` | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` |
| Continue | `--continue` | `--continue` | `--continue` | `--continue` | `-C/--continue` | `exec resume --last` | `--continue` |
| Model flag | `-m MODEL` | `--model MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | (config only) |
| Quiet/non-interactive | (default headless) | (default headless) | (default headless) | `-Q` | (default with `-p`) | (default with `exec`) | (default with `--print`) |

## `scripts/delegate.sh` beyond launch

`helpers/scripts/delegate.sh` also has `status`, `verify`, `reconcile`, and `next-id` subcommands (`docs/usage.md` documents the user-facing behavior; `skills/shared/workflow.md` wires them into the workflow steps). Internally:

- **Supervisor design**: launch does not background the agent directly. It generates `.delegate/tasks/TASK-N.supervisor.sh` (a real file, kept for inspection) and runs it via `nohup bash SUP_FILE &`. The supervisor forks the agent as *its own* child, so `wait` yields the agent's real exit code — not an inference from "the process disappeared" — and races a timeout timer against that `wait`, cancelling the timer itself the instant the agent exits. This removes the "must remember to cancel the watchdog on success" step entirely for this path (the manual/prose fallback in each SKILL.md still needs it, since it can't restructure itself this way).
- **`ps` portability layer**: `_ps_fixed_field`/`_ps_children_fixed` exist because Cygwin/MSYS `ps` (what Git Bash on Windows ships) does not support `-o <field>=` at all — only fixed-column `-f`/`-l`/`-ef` output. These fall back to reading the column headers dynamically and mapping by name, rather than hardcoding positions. Without this fallback, the fingerprint/pgid/child-scan safety features silently no-op on Windows (they degrade gracefully either way — this fallback just makes them actually activate there).
- **PID-reuse guard**: `kill_tree` records a best-effort fingerprint (`ps -o lstart=`, falling back to full `comm`/command line) at launch and refuses to signal a PID whose live fingerprint no longer matches — it isn't the agent anymore, some unrelated process reused the PID.
- **Process-group kill**: only attempted when launch *verified* the recorded PID is its own group leader (`pgid == pid`) — `kill -SIG -PID` otherwise risks hitting an unrelated live group that happens to share that numeric id. This is rarely available on Windows/MSYS (no job-control isolation, no `setsid`); the child-scan (one level, via `pkill -P` or the `ps` fallback) is the primary mechanism there.
- **`next-id` locking**: `mkdir`-based (atomic on every platform this repo targets, unlike `flock`, which doesn't exist on macOS or MSYS), with a 30s staleness check so a lock left behind by a crashed process doesn't deadlock future callers forever.

## Running tests

```bash
bash tests/run-tests.sh   # no external dependencies
```

## Known gotchas

- **opencode v0.15+**: known hang where the process doesn't exit after completing. The watchdog (SIGTERM + 30s SIGKILL) handles this.
- **pi path corruption**: `cd` changes the shell's cwd. Capture `PROJECT_ROOT="$(pwd)"` before `cd`ing and use absolute paths for all `.delegate/tasks/*` references.
- **hermes/kimi/agy — same cd issue**: same fix as pi. All three have no `--dir` flag.
- **`cd X && cmd &` captures the wrong PID**: for pi/hermes/kimi/mimo's cd-fallback, `cd` must be its own statement on its own line, never joined to the launch line via `&&` before backgrounding. `cd X && cmd &` backgrounds the *whole compound list* as one job, so bash forks a wrapper subshell to run it and `$!` becomes that wrapper's PID instead of `cmd`'s — the same class of bug the codex fix below addresses, just via `&&` instead of a pipe. (Found while building `delegate.sh`'s supervisor: its generated script backgrounds `$CD_LINE$INNER_CMD &`, and `CD_LINE` must end in a real newline, not `&& `.)
- **mimo flags**: `--dangerously-skip-permissions`, `--dir`, and `--file` are checked at runtime via `mimo run --help`. Only flags confirmed present are used.
- **codex stdin**: uses `{ printf ...; cat "$TASK_FILE"; } | nohup codex exec ... - &` with codex as the **last** pipeline element — `$!` is the last pipeline command's PID, so the watchdog and liveness checks target codex itself. (A `nohup bash -c '... | codex ...'` wrapper captures the bash PID; SIGTERM to bash doesn't reach the piped codex child.) The framing `printf` is mandatory — piping the raw handoff risks Codex treating it as content to discuss rather than a task to execute.
- **codex no `--continue` flag**: resume uses `codex exec resume --last` (a subcommand, not a flag). It still needs an instruction — pipe a continuation prompt via stdin; an empty invocation will idle or exit.
- **agy no model flag**: model selection is config-only. If user requests a model, instruct them to update Agy's config file instead.
- **hermes `--worktree` built-in flag**: hermes has its own worktree management. Do NOT pass `--worktree` — the skill manages worktrees itself to maintain cross-agent consistency in TODO.md.
- **Windows PATH**: after `npm install -g`, restart your terminal so the new binary is on the shell PATH that Claude Code uses.
- **TODO.md has no lock of its own**: two concurrent delegations computing the next `TASK-N` manually can collide. `bash scripts/delegate.sh next-id` (see `skills/shared/workflow.md` Step 1) closes this with an `mkdir`-based lock; prefer it whenever `delegate.sh` is present.
- **watchdog must be cancelled on completion — manual/prose path only**: the Step 4 watchdog subshell sleeps until timeout and will fire even after success, risking PID reuse. The shared workflow's Case 4 (and the terminal-failure branches) cancel it — don't skip that step. When `scripts/delegate.sh` launched the task, its supervisor cancels its own timer automatically the instant the agent exits; there's nothing to remember.
- **`grep -h pattern FILE1 FILE2` exits nonzero if either file is missing, even on a real match in the other**: hit `delegate.sh`'s `next-id` when `TODO-ARCHIVE.md` (commonly absent) was piped through `2>/dev/null | ... || LAST_N=""` — the `||` fallback fired on grep's nonzero *exit code* even though it had already printed the correct match to stdout, silently discarding it. Fixed by neutralising grep's own exit status inside the pipe (`{ grep ... || true; } | ...`) rather than catching failure at the end. Any script parsing multi-file grep output under `pipefail` should watch for this.
- **`.delegate/tasks/` must exist before launch**: Step 3 creates it (`mkdir -p .delegate/tasks .delegate/worktrees`). The Step 4 launch blocks write PID/log/retries files into it and rely on this; skip Step 3 and a first-ever delegation fails on the PID write.
- **never use a test's own `$$` to simulate "a live agent process"**: sandbox cleanup helpers that kill whatever PID a `.pid` file names will kill the test harness itself if that file happens to contain the harness's own PID. Use a genuine disposable child (`sleep 100 &`) instead.

## Launch safety and compatibility

`helpers/scripts/delegate.sh` omits automatic permission-bypass flags and refuses
to launch if a verified git worktree cannot be created or reused. Codex uses the
`workspace-write` sandbox. A runtime may still refuse an operation or wait for
an approval in background mode; inspect its log rather than enabling bypasses
automatically. Host configuration and each runtime's own policies still apply.
This helper does not add permission checks or an OS sandbox to a runtime that
lacks them.

Two independent, per-launch opt-ins are available:

```bash
# Accept edits in the original project if no worktree can be created.
DELEGATE_ALLOW_UNISOLATED=1 bash helpers/scripts/delegate.sh pi TASK-1 1800

# Explicitly accept runtime permission bypass in a controlled environment.
DELEGATE_ALLOW_UNSAFE_FLAGS=1 bash helpers/scripts/delegate.sh pi TASK-1 1800
```

Both variables accept only `0` (default) or `1`. The second enables supported
OpenCode `--auto`/legacy skip-permissions, Pi `--approve`, MiMo skip-permissions,
Hermes YOLO/hook acceptance, Kimi YOLO, Codex approval/sandbox bypass or Agy
skip-permissions. Opt-in is never inferred from worktree availability or retry.
Git worktrees separate code edits; **they are not an OS security boundary**.
They share repository metadata and do not constrain processes, secrets, network
access or host filesystem access. Use an independently configured sandbox when
those restrictions are needed.

Task IDs must be `TASK-N` with positive decimal N; timeouts must be positive
decimal integers. Delegation directories/state files may not be symlinks, and
an existing worktree must match this repository and `<runtime>/TASK-N` branch.
These checks guard accidental traversal/reuse; they do not defend against a
concurrent hostile process modifying paths after validation.

Maintain `skills/` as the source and run `bash helpers/scripts/sync-skills.sh`
after edits. `--check` verifies distributed workflow copies and `.agents/skills/`
without writing files. Copies remain self-contained for single-skill installs.
No root license file is added in this change: the existing MIT declarations
remain subject to the owner's licensing/provenance review.
