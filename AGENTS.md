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
│   ├── workflow.md          # copy of skills/shared/workflow.md
│   └── scripts/delegate.sh  # copy of helpers/scripts/delegate.sh (the launcher)
└── delegate-to-<runtime>/
    ├── SKILL.md             # Step 4: detect, validate, launch, retry for one runtime
    ├── workflow.md          # copy of skills/shared/workflow.md
    └── scripts/delegate.sh  # copy of helpers/scripts/delegate.sh (the launcher)
```

Every skill folder is **self-contained**: it carries its own `workflow.md` and
`scripts/delegate.sh` copies and references them as local paths (`workflow.md`,
never `../shared/workflow.md`). The workflow resolves the launcher as
`$DELEGATE_SH` — a project-local `scripts/delegate.sh` wins, otherwise the
skill's bundled copy — so the tested launch/monitor path works from any install.
This matters because single-skill installers (`npx skills add owner/repo --skill
delegate-to-kimi`, the [skills.sh](https://skills.sh) CLI) fetch only the named
subdirectory — a sibling `../shared/` reference would 404. `skills/shared/` has no
`SKILL.md` of its own, so skill scanners ignore it entirely; it exists only so a
maintainer edits the workflow (and `helpers/scripts/delegate.sh`) in one place and syncs them out to the 8 skill folders:

```bash
bash helpers/scripts/sync-skills.sh
bash helpers/scripts/sync-skills.sh --check
```

`tests/test-structure.sh` enforces that every copy stays byte-identical to the
canonical source, and that `.agents/skills/` mirrors `skills/` exactly. Never
hand-edit `skills/*/scripts/delegate.sh` — edit `helpers/scripts/delegate.sh` and sync.

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
├── test-safety.sh               # permission defaults, isolation, validation, symlinks
├── test-upstream.sh             # upstream manifest + contract checker (no network)
├── check-cli-contract.py        # real CLIs' --help vs flags delegate.sh passes
└── fixtures/
    └── mock-bin/                # mock CLI binaries used by test-behavior.sh
```

### `.github/` — CI and upstream tracking

```
.github/
├── upstream-sources.yml         # per-runtime docs/changelog URLs, verified version, required flags
└── workflows/
    ├── test.yml                 # mock test suite, Ubuntu + Windows Git Bash
    ├── cli-contract.yml         # weekly: npm-install latest CLIs, run check-cli-contract.py, one deduped issue on drift
    └── upstream-watch.md        # weekly GitHub Agentic Workflow (gh aw): AI reads upstream docs/changelogs, files issues
```

`upstream-watch.md` is the source; `gh aw compile` generates the
`upstream-watch.lock.yml` that Actions actually runs. **Commit both, and re-run
`gh aw compile` after every edit to the `.md`.** It needs an `ANTHROPIC_API_KEY`
repository secret (engine `claude`). When a runtime flag changes, update
`.github/upstream-sources.yml` (`verified`, `latest_seen`, `require`) together with
the AGENTS.md CLI table — `tests/test-upstream.sh` fails if their versions disagree
or a required flag is not one `delegate.sh` uses.

Three layers: structure tests grep-match frontmatter, text patterns and known-bug regressions; behavior tests actually *execute* `delegate.sh` against mocks in isolated sandboxes (launch, PID capture, exit codes, timeouts, stop/relaunch, `--continue`/`--model` flag mapping, verify, reconcile, next-id); safety tests cover permission defaults, isolation failures, input validation and symlink refusal. Run `bash tests/run-tests.sh` for the current count.

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
- For tools with no `--dir` flag (pi, hermes, kimi, agy), capture `PROJECT_ROOT="$(pwd)"` **before** `cd`ing into the worktree so all `.delegate/tasks/*` paths stay correct. The launcher `cd`s into the worktree for every runtime, even those with a directory flag: the process cwd is what contains relative writes.
- All skills reference their own local `workflow.md` copy (never `../shared/workflow.md` — that breaks single-folder installs). Edit `skills/shared/workflow.md` and re-sync copies; don't hand-edit a distributed copy directly.

## CLI differences that matter

| Feature | opencode | pi | mimo | hermes | kimi | codex | agy |
|---------|----------|----|------|--------|------|-------|-----|
| Run command | `opencode run "msg"` | `pi -p "msg"` | `mimo run "msg"` | `hermes chat -q "msg"` | `kimi -p "msg"` | `printf framing \| codex exec -` | `agy --print "msg"` |
| Handoff delivery | `--file path` | `@path` positional | `--file path` (check) | absolute path in prompt | absolute path in prompt | stdin (`-`) | absolute path in prompt |
| Working dir | `--dir path` | `cd` before (use PROJECT_ROOT) | `--dir path` (check) | `cd` before (use PROJECT_ROOT) | `cd` before (use PROJECT_ROOT) | `-C/--cd path` (not on `resume`) | `cd` before + `--add-dir path` |
| Skip perms (opt-in only) | `--auto` (≥ v1.17; older: `--dangerously-skip-permissions`) | `--approve` (trusts project-local pi files; pi never prompts for tools) | `--dangerously-skip-permissions` / `--yolo` (check) | `--yolo --accept-hooks` | `-y/--yolo` | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` |
| Continue | `--continue` | `--continue` | `--continue` | `--continue` | `-c/--continue` (lowercase; no `-C`) | `exec resume --last` (cwd-filtered; no `-C`/`-s`) | `--continue` |
| Model flag | `-m MODEL` | `--model MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | `-m MODEL` | `--model MODEL` |
| Model list | `opencode models` | `pi --list-models` | `mimo models` | — | — | — | `agy models` |
| Quiet/non-interactive | (default headless) | (default headless) | (default headless) | `-Q` | (default with `-p`) | (default with `exec`) | (default with `--print`) |

Last verified against `--help` of opencode 1.18.32, pi 1.0.0, mimo 0.1.13, Hermes Agent 0.20.4, kimi-code 0.34.0, codex-cli 0.167.0 and agy 1.4.9 (2026-11). Re-check after major CLI upgrades — flags have drifted before (opencode `--dangerously-skip-permissions` → `--auto`, agy gaining `--model`).

Newest upstream releases seen 2026-11-06 (npm `latest` / GitHub release tags): opencode 1.19.5, pi 1.5.0, mimo 0.1.16, kimi-code 2.5.2, Hermes Agent 0.23.0 (not yet verified against `--help`). Note `@opencode/core` 2.x on npm is a library, not the `opencode-ai` CLI. `python tests/check-cli-contract.py` re-checks every installed CLI; `.github/workflows/cli-contract.yml` does it weekly against the latest npm releases.

## `delegate.sh` beyond launch

`helpers/scripts/delegate.sh` (bundled into every skill as `scripts/delegate.sh`) also has `status`, `stop`, `verify`, `reconcile`, `next-id`, `cleanup` and `version` subcommands, and launch accepts `--continue` (resume the runtime's previous session — the self-healing retry) and `--model ID` (`docs/usage.md` documents the user-facing behavior; `skills/shared/workflow.md` wires them into the workflow steps). Internally:

- **Supervisor design**: launch does not background the agent directly. It generates `.delegate/tasks/TASK-N.supervisor.sh` (a real file, kept for inspection) and runs it via `nohup bash SUP_FILE &`. The supervisor forks the agent as *its own* child, so `wait` yields the agent's real exit code — not an inference from "the process disappeared" — and races a timeout timer against that `wait`, cancelling the timer itself the instant the agent exits. This removes the "must remember to cancel the watchdog on success" step entirely for this path (the manual/prose fallback in each SKILL.md still needs it, since it can't restructure itself this way).
- **`ps` portability layer**: `_ps_fixed_field`/`_descendants` exist because Cygwin/MSYS `ps` (what Git Bash on Windows ships) does not support `-o <field>=` at all — only fixed-column `-f`/`-l`/`-ef` output. These fall back to reading the column headers dynamically and mapping by name, rather than hardcoding positions. Without this fallback, the fingerprint/pgid/descendant-scan safety features silently no-op on Windows (they degrade gracefully either way — this fallback just makes them actually activate there).
- **Descendant kill**: `_descendants` walks the whole `ps` table (children, grandchildren, …, deepest first) and `_signal_descendants` is used by `kill_tree` (`stop`) *and* by the supervisor's timer, which is exported into the generated script. The launched PID is often not the engine — an npm shim that does not `exec`, a CLI that spawns its worker, the agent's own shells and test runners — and on Git Bash and stock macOS there is no `setsid`, so no process group to signal: before this, a timeout there killed only the top-level PID and left the real agent running (`tests/test-behavior.sh`, "grandchild" tests).
- **Relaunch semantics**: a launch refuses to start while the task's previous agent is still alive (two agents in one worktree corrupt each other — `stop` it first), clears the previous attempt's per-run state (pid, exitcode, fingerprint, pgid, timeout/stop markers, stall markers), rotates the log to `TASK-N.log.prev`, and creates `TASK-N.retries` only if missing — the caller increments it, and resetting it on relaunch would make the "max 2 retries" rule unreachable.
- **Timeout / stop markers**: the supervisor's timer writes `TASK-N.timedout` before signalling, and `stop` writes `TASK-N.stopped`, so `status` can report `TIMED_OUT` / `STOPPED` instead of a generic nonzero exit. The markers are checked *before* the exit code and do not require one: if the supervisor died, no `.exitcode` is ever written, and a stopped task must not read as `LAUNCH_FAILED` (which Step 5 Case 1 relaunches).
- **Worktree prune**: launch runs `git worktree prune` before `git worktree add`. A worktree directory deleted by hand stays registered as "prunable" and blocks re-adding the same path — a task could never be resumed after a manual cleanup, with an error that blamed isolation. The real git error is now part of the message.
- **Stall scan prunes `.delegate` and `.git`**: `status`'s filesystem-activity signal scans the work dir; when that is the project root (unisolated), its own `.log.size`/`.lastpoll` files counted as activity and `STALLED` never fired.
- **`cleanup`** is the post-merge teardown (`git worktree remove` + `git branch -d`): it refuses while `task_agent_alive`, refuses *before removing anything* when the branch is not an ancestor of HEAD (`git merge-base --is-ancestor`) or the worktree is dirty, and only `--force` uses `remove --force` / `branch -D`. Merging stays manual.
- **Launcher version**: `DELEGATE_VERSION` (printed by `version`) must equal every skill's `metadata.version` — a structure test enforces it. The workflow's `$DELEGATE_SH` resolver compares a project-pinned `scripts/delegate.sh` with the bundled one via `version` and keeps the bundled copy when the pinned one is older (a pre-1.4 copy has no `version` and counts as oldest). Bump `DELEGATE_VERSION` together with the skills.
- **Portable mtime**: `_mtime_epoch` (`stat -c` → `stat -f` → `date -r`) backs the `next-id` stale-lock check. BSD/macOS `date -r` takes epoch *seconds*, so `date -r <file>` fails there and silently disabled the self-heal; CI only runs GNU platforms, so keep macOS in mind when adding coreutils calls.
- **`.delegate/` stays out of `git status`**: launch and `next-id` append `.delegate/` to the repository's `info/exclude` (never committed). Without it, the first delegation leaves an untracked `.delegate/` and every later Step 0 sees a dirty tree.
- **PID-reuse guard**: `kill_tree` records a best-effort fingerprint (`ps -o lstart=`, falling back to full `comm`/command line) at launch and refuses to signal a PID whose live fingerprint no longer matches — it isn't the agent anymore, some unrelated process reused the PID.
- **Process-group kill**: only attempted when launch *verified* the recorded PID is its own group leader (`pgid == pid`) — `kill -SIG -PID` otherwise risks hitting an unrelated live group that happens to share that numeric id. This is rarely available on Windows/MSYS or macOS (no `setsid`); the recursive descendant scan is the primary mechanism there, the group kill is a second layer where it exists.
- **`next-id` locking**: `mkdir`-based (atomic on every platform this repo targets, unlike `flock`, which doesn't exist on macOS or MSYS), with a 30s staleness check so a lock left behind by a crashed process doesn't deadlock future callers forever.

## Running tests

```bash
python3 -m pip install -r tests/requirements.txt  # PyYAML for all eight frontmatter checks
bash tests/run-tests.sh                         # mock CLIs; no model/provider calls
```

Set `PYTHON` to a Python 3 executable to use the same interpreter as the dependency
install (absolute paths are supported). Without an override, tests try `python3`,
then `python`. CI uses setup-python's exact output path for both operations.

## Known gotchas

- **opencode v0.15+**: known hang where the process doesn't exit after completing. The watchdog (SIGTERM + 30s SIGKILL) handles this. The source repo moved from `sst/opencode` to `anomalyco/opencode` (the old name redirects).
- **kimi-code ≥ 2.0 print mode**: `-p` is auto-permission (never prompts; static deny rules still apply) and is rejected together with `-y/--yolo`, `--auto` or `--plan`. The launcher reads `kimi --version` and never adds `-y` on 2.x, warning instead — so kimi 2.x cannot keep tool approvals in background mode at all.
- **pi `--approve` is help-detected**: pi 1.5 introduced persistent project trust (`trust.json`); the launcher adds `--approve` only if `pi --help` lists it.
- **codex `--full-auto` is gone**: use `--sandbox workspace-write` (what the launcher passes). Newer codex also has `--approve-for-me`; the launcher does not use it.
- **mimo docs omit `--dir` on `run`**: the launcher help-detects it and always `cd`s into the worktree anyway.
- **pi path corruption**: `cd` changes the shell's cwd. Capture `PROJECT_ROOT="$(pwd)"` before `cd`ing and use absolute paths for all `.delegate/tasks/*` references.
- **hermes/kimi/agy — same cd issue**: same fix as pi. All three have no `--dir` flag.
- **`cd X && cmd &` captures the wrong PID**: for pi/hermes/kimi/mimo's cd-fallback, `cd` must be its own statement on its own line, never joined to the launch line via `&&` before backgrounding. `cd X && cmd &` backgrounds the *whole compound list* as one job, so bash forks a wrapper subshell to run it and `$!` becomes that wrapper's PID instead of `cmd`'s — the same class of bug the codex fix below addresses, just via `&&` instead of a pipe. (Found while building `delegate.sh`'s supervisor: its generated script backgrounds `$CD_LINE$INNER_CMD &`, and `CD_LINE` must end in a real newline, not `&& `.)
- **mimo flags**: `--dangerously-skip-permissions`, `--dir`, and `--file` are checked at runtime via `mimo run --help`. Only flags confirmed present are used.
- **codex stdin**: uses `{ printf ...; cat "$TASK_FILE"; } | nohup codex exec ... - &` with codex as the **last** pipeline element — `$!` is the last pipeline command's PID, so the watchdog and liveness checks target codex itself. (A `nohup bash -c '... | codex ...'` wrapper captures the bash PID; SIGTERM to bash doesn't reach the piped codex child.) The framing `printf` is mandatory — piping the raw handoff risks Codex treating it as content to discuss rather than a task to execute.
- **codex no `--continue` flag**: resume uses `codex exec resume --last` (a subcommand, not a flag). It still needs an instruction — pipe a continuation prompt via stdin; an empty invocation will idle or exit. `resume` accepts **neither `-C/--cd` nor `-s/--sandbox`**: `cd` into the worktree first (`--last` is filtered to the current directory) and pass the sandbox as `-c 'sandbox_mode="workspace-write"'`.
- **kimi continue is lowercase `-c`**: kimi-code has no `-C` flag; `-c/--continue` resumes the previous session for the working directory.
- **pi has no tool-approval prompts**: `--approve` only trusts project-local pi resources (extensions/settings) for the run. pi's bash/edit/write tools run unprompted regardless, so isolation for pi is the worktree plus whatever external sandbox the operator provides.
- **`--file` is an array option in opencode/mimo** (yargs `[array]`): it swallows following non-flag words, so the launcher puts `--file <path>` last.
- **`verify` runs under `set -e -o pipefail`**: before v1.4.0 only the last line's status counted, so a failing `npm test` followed by a passing `test -f` reported PASS.
- **`omo` is a TODO.md label, not a branch or a launcher runtime**: oh-my-opencode (npm `oh-my-opencode`, bins `oh-my-opencode`/`oh-my-openagent`; `omo` from `omo-ai`) is an opencode plugin. Launch it as `opencode` through the launcher — the branch must be `opencode/TASK-N`, which `validate_worktree` enforces; `omo/TASK-N` made every omo launch fail. Its own runner `oh-my-opencode run` (verified 5.1.62) takes `-d/--directory`, `-m/--model`, `--session-id`; it has **no** `--dir`, `--file`, `--continue` or `--yes`.
- **hermes `--worktree` built-in flag**: hermes has its own worktree management. Do NOT pass `--worktree` — the skill manages worktrees itself to maintain cross-agent consistency in TODO.md.
- **Windows PATH**: after `npm install -g`, restart your terminal so the new binary is on the shell PATH that Claude Code uses.
- **TODO.md has no lock of its own**: two concurrent delegations computing the next `TASK-N` manually can collide. `bash "$DELEGATE_SH" next-id` (see `skills/shared/workflow.md` Step 1) closes this with an `mkdir`-based lock **plus a reservation file** (`.delegate/tasks/TASK-N.reserved`). The lock alone was not enough: the caller appends its ledger block only after `next-id` returns, so a second caller in that window read the same max.
- **watchdog must be cancelled on completion — manual/prose path only**: the Step 4 watchdog subshell sleeps until timeout and will fire even after success, risking PID reuse. The shared workflow's Case 4 (and the terminal-failure branches) cancel it — don't skip that step. When the launcher started the task, its supervisor cancels its own timer automatically the instant the agent exits; there's nothing to remember.
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

Maintain `skills/` (and `helpers/scripts/delegate.sh`) as the source and run
`bash helpers/scripts/sync-skills.sh` after edits. `--check` verifies distributed
workflow and launcher copies and `.agents/skills/` without writing files. Copies remain self-contained for single-skill installs.
The repository is MIT licensed (`LICENSE`); every skill declares `license: MIT`.
Plugin manifests (`.claude-plugin/`, `.codex-plugin/`, `.agents/plugins/`) carry
the same version as `DELEGATE_VERSION`; bump all of them together (a structure
test checks it). Codex caches an install by that version.
