# Changelog

All notable changes to this project are documented here. Versions correspond to
the `metadata.version` field in each skill's `SKILL.md`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Launches now refuse worktree failures by default. Project-root execution
  requires the separate `DELEGATE_ALLOW_UNISOLATED=1` opt-in and emits a warning.
- Runtime approval/sandbox bypass is disabled by default across all seven
  adapters. `DELEGATE_ALLOW_UNSAFE_FLAGS=1` explicitly enables supported bypass
  flags; Codex otherwise uses `workspace-write`. Blocking/refused approvals must
  be reported instead of automatically bypassed during recovery.
- Validate task identifiers, timeout/opt-in values, delegation paths and reused
  worktree ownership. Every runtime starts in the verified working directory.
- Align manual skill instructions and the `.agents/skills/` distribution with
  those defaults, and provide a canonical-source mirror sync/check command.

### Added

- Mock process/filesystem safety regressions and Ubuntu/Windows Git Bash CI,
  including worktree failure, unsafe opt-ins, path traversal, foreign worktrees,
  symlinks and project paths containing spaces. No model calls are made by CI.

## [1.3.1] — 2026-07-31

Self-contained skill folders: each `skills/delegate-to-*/` now carries its own
`workflow.md` copy instead of referencing a sibling `../shared/workflow.md`.
Motivated by single-skill installers — e.g. the [skills.sh](https://skills.sh)
CLI (`npx skills add owner/repo --skill <name>`) — which fetch only the named
subdirectory and never pull sibling folders, so a `../shared/` reference
silently 404s under that install path.

### Changed

- All 8 `SKILL.md` files reference a local `workflow.md` instead of
  `../shared/workflow.md`.
- `skills/shared/workflow.md` is now a maintainer-only canonical source (no
  `SKILL.md` of its own, so skill scanners skip it) — edit it once, then sync
  copies to each skill folder: `for skill in skills/delegate-to-*; do cp
  skills/shared/workflow.md "$skill/workflow.md"; done`.
- `tests/test-structure.sh` gained a drift check: every per-skill
  `workflow.md` must stay byte-identical to `skills/shared/workflow.md`.
- README/`docs/install.md`/`AGENTS.md` updated to drop the now-unnecessary
  "install `shared/` alongside every skill" step, and document the
  skills.sh CLI as an install path.
- Fixed a stale GitHub org in README's clone URL
  (`bassem-io` → `bassemZohdy`, matching the actual `origin` remote).

## [1.3.0] — 2026-07-12

Resilience pass: `helpers/scripts/delegate.sh` gains real monitoring/management
subcommands and a rearchitected launch path, closing gaps found in a review of
how well the delegation mechanics hold up under crashes, PID reuse, and
platform differences (this repo is developed and tested on Windows/Git Bash,
which surfaced several of these).

### Added

- **`delegate.sh status TASK-N`** — machine-readable liveness/outcome check
  (`STATE=RUNNING|STALLED|EXITED_OK|EXITED_FAILED|LAUNCH_FAILED|NOT_FOUND`,
  plus `EXITCODE=`/`LOG_SIZE=`/`RETRIES=`). Cross-checks log growth against
  worktree filesystem activity before calling a task `STALLED`, so a healthy
  agent doing a long silent compile isn't misread as stuck.
- **`delegate.sh verify TASK-N`** — extracts and runs the fenced ` ```bash `
  block under a handoff's `## Verification Expectations` section, reporting
  `STATE=PASS`/`FAIL` with the real exit code. Turns "completed only when
  verification passes" from a judgment call into something enforceable the
  same way regardless of which host tool is running the workflow.
- **`delegate.sh reconcile`** — reports `TODO.md` entries stuck at
  `status: in_progress` whose process isn't actually running, the case where
  the AI session that launched a task crashed or closed before it could
  review completion and nothing was ever going to mark it done or failed.
- **`delegate.sh next-id`** — allocates the next `TASK-N` under an
  `mkdir`-based lock (portable to every platform this repo targets, including
  Windows, unlike `flock`) with 30s staleness recovery, closing the
  documented "TODO.md has no lock" race for callers that use it.
- **Real exit-code capture**: launch no longer backgrounds the agent directly.
  It generates a small supervisor script (`TASK-N.supervisor.sh`, kept for
  inspection) that forks the agent as *its own* child, so `wait` yields the
  agent's true exit code instead of inferring outcome from "the process is
  gone." The supervisor races a timeout timer against that `wait` and
  cancels the timer itself the instant the agent exits — the "must remember
  to cancel the watchdog on success" step from earlier versions is now
  automatic for anything launched this way.
- **PID-reuse guard**: a best-effort process fingerprint (`ps -o lstart=`,
  falling back to the full command line) is recorded at launch; a later kill
  is skipped if the live process's fingerprint no longer matches, rather than
  risking a signal to an unrelated process that reused the PID.
- **Process-tree kill**: stalled/timed-out agents are terminated via a child
  scan (one level, catching helper processes the agent spawned) plus a
  process-group kill — but the group kill only fires when launch *verified*
  the recorded PID is its own group leader, never blindly, since `kill -SIG
  -PID` against an unverified id risks hitting an unrelated live group that
  happens to share that number.
- **Cygwin/MSYS `ps` portability layer**: Git Bash on Windows ships a `ps`
  that doesn't support `-o <field>=` at all, only fixed-column `-f`/`-l`/`-ef`
  output — the fingerprint/pgid/child-scan features above would silently
  never activate there otherwise. Added a fallback that reads the fixed
  format's own header line and maps columns by name.
- **`shared/workflow.md` existence guard**: every `SKILL.md` now tells the
  model to stop and ask for a `shared/`-inclusive reinstall if
  `../shared/workflow.md` is missing, instead of improvising the workflow
  from memory when a partial install broke the reference.
- **`$ARGUMENTS` non-substitution fallback**: `skills/shared/workflow.md` now
  notes that if the `## Task` section still literally reads `$ARGUMENTS`
  after a host is supposed to have substituted it, treat the user's original
  request text as the task description instead.
- **Watchdog now `nohup`'d** in every per-runtime `SKILL.md`'s manual/prose
  launch block and in `helpers/adapters/generic-prompt.md` — a bare
  backgrounded subshell is not guaranteed to survive the calling
  terminal/session closing; `delegate.sh`'s supervisor already got this via
  its own `nohup bash SUP_FILE`.
- **`.agents/skills/` mirror committed**, kept in sync via a structure test
  (added in 1.2.4; this release is the first with real drift risk from the
  volume of changes, so it's called out again here).

### Fixed

- **`cd X && cmd &` captured the wrong PID**: the pi/hermes/kimi/mimo-fallback
  cd-then-launch pattern, when written as `cd "$WORK_DIR" && cmd &`,
  backgrounds the *whole compound list* as one job — bash forks a wrapper
  subshell to run it, and `$!` becomes that wrapper's PID instead of `cmd`'s.
  The same class of bug the 1.2.4 codex fix addressed, reintroduced here via
  `&&` instead of a pipe while building the new supervisor. `cd` must be its
  own statement on its own line before the (unjoined) launch line.
- **`grep -h pattern TODO.md TODO-ARCHIVE.md` silently discarding a real
  match**: grep exits nonzero when either file is missing, even if it matched
  in the other; under `pipefail`, a naive `|| LAST_N=""` catch on the whole
  pipeline fired on that exit code and threw away a correct result. First hit
  while building `next-id`; fixed by neutralising grep's own exit status
  inside the pipe rather than catching failure at the end.
- **Pipeline exit status vs. `pipefail` in test assertions**: two new
  `verify`/`status` tests piped delegate.sh's own designed-nonzero exit codes
  directly into `grep -q ...`, which under `pipefail` reports the *pipeline's*
  exit status (the rightmost nonzero stage) even when grep matched
  successfully — silently failing correct behavior. Fixed by capturing output
  via command substitution before grepping the string.
- **Test harness self-kill**: a new `reconcile` test used its own shell's
  `$$` to simulate "a live agent process," which `cleanup_sandbox`'s generic
  "kill whatever every `.pid` file names" teardown then dutifully
  `SIGKILL`ed, taking down the test harness mid-run. Fixed to use a
  disposable child process instead.

## [1.2.4] — 2026-07-12

### Fixed

- **empty-directory fallback** (`helpers/scripts/delegate.sh`): when the project
  was not a git repo or `git worktree add` failed, the script created an empty
  plain directory under `.delegate/worktrees/` and launched the agent inside it
  — with zero project files to work on. It now falls back to the project root
  (matching what `skills/shared/workflow.md` and every SKILL.md already
  specified). Behavior test updated to assert the root fallback.
- **codex watchdog killed the wrapper, not codex** (`delegate.sh`,
  `skills/delegate-to-codex/SKILL.md`, `helpers/adapters/generic-prompt.md`):
  the launch wrapped the stdin pipeline in a backgrounded `bash -c` string, so
  `$!` captured the wrapper shell's PID. SIGTERM to that shell does not
  propagate to the piped codex child, so timeouts and stall-kills left codex
  running. Restructured so codex is the last element of the backgrounded
  pipeline — `$!` is now codex's own PID. Behavior test now asserts the
  recorded PID matches the codex process; structure test forbids the wrapper.
- **deprecated opencode flag preferred over current one** (`delegate.sh`,
  `skills/delegate-to-opencode/SKILL.md`, `generic-prompt.md`): auto-approval
  flag detection checked `--auto` first and let `--dangerously-skip-permissions`
  overwrite it, so a version supporting both got the deprecated flag. Order
  swapped so `--auto` wins.
- **unquoted flag strings broke on paths with spaces** (`delegate.sh` mimo
  branch, `skills/delegate-to-mimo/SKILL.md`, omo block in
  `skills/delegate-to-opencode/SKILL.md`): flags built as flat strings
  (`MIMO_DIR_FLAG="--dir $WORK_DIR"`) word-split on spaces in the project path.
  Now built as bash arrays with the `${arr[@]+...}` expansion (safe under
  `set -u` on bash 3.2).
- **task-ID allocation by block count** (`skills/shared/workflow.md`,
  `helpers/adapters/generic-prompt.md`, `helpers/hermes/delegate-tasks/SKILL.md`):
  the next TASK-N was derived by counting `## [TASK-` blocks, which collides
  with a surviving task if any block was ever removed. Now takes the highest
  existing task number across `TODO.md` and `TODO-ARCHIVE.md` and adds 1.

### Added

- **`.agents/skills/` mirror committed and parity-tested**: the agentskills.io
  project-level mirror was maintained locally (the 1.2.3 notes reference it) but
  never committed. It is now tracked, and a structure test fails whenever
  `diff -r skills .agents/skills` is non-empty.

## [1.2.3] — 2026-07-04

### Fixed

- **runtime artifacts hardcoded to `.opencode/`** (`helpers/scripts/delegate.sh`
  and all per-runtime `SKILL.md` files): task handoff docs, worktrees, PID/log
  files, and retry counters were written under `.opencode/tasks` and
  `.opencode/worktrees` regardless of which runtime (`mimo`, `pi`, `hermes`,
  `kimi`, `codex`, `agy`) was actually delegating the task. Renamed to the
  runtime-agnostic `.delegate/tasks` and `.delegate/worktrees` across
  `delegate.sh`, both `skills/` and `.agents/skills/` mirrors, docs, tests, and
  `.gitignore`.

## [1.2.2] — 2026-07-04

### Fixed

- **invalid YAML frontmatter** (`skills/delegate-to-any/SKILL.md`): the
  `compatibility:` field's value contained an unquoted `at least one of:` colon,
  which YAML parses as a nested mapping key rather than plain text. This broke
  frontmatter parsing for every tool that loads the skill (Claude Code, other
  agentskills.io-compatible runtimes), so `/delegate-to-any` failed to load
  entirely. The value is now quoted. Added a YAML-parse check to
  `tests/test-structure.sh` (via `python3 -c ... < file`, piped through stdin to
  avoid MSYS/Windows path-translation issues with `python3 -c "... r'$path' ..."`)
  so every skill's frontmatter is now validated as parseable YAML, not just
  checked for the `---` delimiter.

## [1.2.1] — 2026-07-03

Bugs found via a live end-to-end smoke test (`/delegate-to-any` against installed
opencode v1.17.13) plus a workflow-ordering gap flagged during review.

### Fixed

- **stale opencode auto-approval flag** (`delegate-to-opencode`, `delegate-to-mimo`,
  `delegate-to-any`, `helpers/scripts/delegate.sh`, `helpers/adapters/generic-prompt.md`,
  `helpers/hermes/delegate-tasks/SKILL.md`): `--dangerously-skip-permissions` no
  longer exists in opencode ≥ v1.17.x (replaced by `--auto`), so every opencode
  launch failed at startup. Flag is now detected from `opencode run --help` output
  instead of hardcoded, matching the pattern already used for mimo's flags.
- **relative `--file` path breaks under `--dir`** (`delegate-to-opencode`,
  `delegate-to-mimo`): passing `--dir <worktree>` changes the runtime's cwd, so a
  relative `--file .opencode/tasks/TASK-N.md` no longer resolves — the worktree
  has no `.opencode/tasks/` directory of its own (it's gitignored, project-root
  only). All `--file`/log/pid paths in these launch blocks are now built from a
  `PROJECT_ROOT` captured before any `--dir`/`cd`. `helpers/scripts/delegate.sh`
  already did this correctly and was unaffected.
- **worktree created before its TODO.md ledger entry exists**
  (`skills/shared/workflow.md`, `helpers/adapters/generic-prompt.md`,
  `helpers/hermes/delegate-tasks/SKILL.md`): Step 1 (create worktree) ran before
  Step 2 (write TODO.md entry), but a git worktree only sees *committed* history —
  since the ledger entry was written as an uncommitted change in the main tree
  afterward, the worktree never contained it, and the uncommitted `TODO.md` also
  tripped the next delegation's Step 0 dirty-tree check. Swapped the order: the
  ledger entry is now written and committed first, then the worktree branches off
  that commit. Completion status updates are committed the same way. Merging the
  worktree's actual code changes into the current branch remains a manual,
  user-facing step (documented in `docs/usage.md`) — never automatic.
- **opencode flag-detection hang in `helpers/scripts/delegate.sh`**
  (`tests/fixtures/mock-bin/opencode`, `tests/fixtures/mock-bin/mimo`,
  `tests/test-behavior.sh`): the auto-approval-flag fix above added
  `$(opencode run --help)` inside `delegate.sh`. Against the test suite's mock
  binaries this hung indefinitely under `MOCK_HANG=1` (the mock had no
  `--help` short-circuit, so the command substitution blocked on the mock's
  infinite heartbeat loop with no timeout — the same hazard the suite already
  had a comment warning about for `pi`/`hermes`/`kimi`, just not yet hit for
  opencode) and, separately, hard-failed under `set -e` in two tests that
  don't set `MOCK_OUT_DIR` (real `--help` needs no env setup, but the mock
  required it before reaching its `--help` branch). Fixed at the root: the
  opencode mock now special-cases `--help` and returns before both the
  `MOCK_OUT_DIR` check and the heartbeat loop, matching the pattern `mimo`'s
  mock already used (which had the identical `MOCK_OUT_DIR`-ordering bug,
  latent but never triggered by an existing test — fixed there too). Updated
  the one test assertion that hardcoded the now-removed
  `--dangerously-skip-permissions` flag to expect `--auto`. Full suite verified
  green across 4 consecutive runs (436/436) with no leaked processes.

## [1.2.0] — 2026-07-03

Follow-up review. Two stale cross-references from the v1.1.0 restructure and one
launcher-script robustness gap.

### Fixed

- **stale `docs/workflow.md` references** (`helpers/scripts/delegate.sh`,
  `TODO.md`): both still pointed at the pre-restructure path; the shared
  workflow doc has lived at `skills/shared/workflow.md` since v1.1.0. Updated
  both references.

### Changed

- **`delegate-to-any` launcher fallback**: the "preferred" launch path
  (`bash scripts/delegate.sh ...`) assumed the script had been copied into the
  target project and had no guard if it was absent. Added an existence check
  that falls back to the per-runtime direct-launch path, matching the pattern
  already used in `helpers/adapters/generic-prompt.md` and the Hermes adapter.

## [1.1.0] — 2026-06-30

Behavioral fixes and hardening from a full skills review. All changes are
backward-compatible. The pre-existing structure-only test suite passed even with
these bugs present, so semantic regression checks were added to prevent
re-occurrence (suite grew from 402 → 420 assertions).

### Fixed

- **omo worktree isolation** (`delegate-to-opencode`, `delegate-to-any`): the
  `oh-my-opencode` launch block checked for `--file` but never set `--dir` or
  `cd`'d into the worktree, so oh-my-opencode ran in the project root and
  defeated the worktree isolation the whole workflow is built around. Now
  help-checks `--dir` and falls back to `cd` (capturing `PROJECT_ROOT` first)
  when `--dir` is unsupported.
- **stale PID in `delegate.sh`**: the `pi`/`hermes`/`kimi`/`mimo` cases wrapped
  the launch in `( cd ... && nohup ... & )`, so `$!` captured the subshell PID
  which dies immediately — breaking Step 5 liveness checks and the watchdog.
  Restructured all four to `cd` directly so `$!` is the real agent PID.
- **watchdog PID-reuse hazard** (`shared/workflow.md`): the watchdog subshell
  sleeps until timeout and was never cancelled on normal completion, so it could
  later `kill` an unrelated process that reused the agent's PID. Case 4 (and the
  terminal-failure branches) now cancel the watchdog.
- **Codex handoff framing** (`delegate-to-codex`, `delegate.sh`,
  `helpers/adapters/generic-prompt.md`, `helpers/hermes/delegate-tasks`): the
  initial launch piped the raw handoff to Codex stdin with no framing, risking
  Codex treating it as content to discuss rather than a task to execute. Now
  prepends a `printf` framing instruction before the handoff.
- **Codex retry message** (`delegate-to-codex`): `codex exec resume --last` was
  invoked with no instruction, causing it to idle or exit. Now pipes a
  continuation prompt via stdin.
- **`delegate.sh` duplicated redirect**: malformed `2>/dev/null 2>/dev/null` on
  the git preflight line.

### Changed

- **`delegate-to-any` deduplicated**: the eight per-runtime launch blocks (which
  had already drifted and caused the omo bug above) were replaced with a
  reference to `delegate-to-<runtime>/SKILL.md` + `delegate.sh` as the single
  source of truth, plus one common-skeleton block for the auditable shared
  mechanics. Shrinks the file by ~230 lines.
- **`.opencode/tasks/` creation is now explicit**: `shared/workflow.md` Step 3
  runs `mkdir -p .opencode/tasks .opencode/worktrees` before Step 4 writes
  PID/log/retries files. Previously this only worked by accident of step
  ordering.

### Added

- **`TODO.md` locking documentation**: `shared/workflow.md` and `AGENTS.md` now
  document that TODO.md has no lock and two concurrent delegations can collide
  on the same `TASK-N`, with mitigations (sequential ID assignment before
  parallel launch, or `flock`).
- **AGENTS.md gotchas** for watchdog cancellation, codex framing/retry, and the
  mkdir requirement.
- **18 semantic regression tests** in `tests/test-structure.sh` covering all the
  above fixes plus a general `WORK_DIR`-defined-but-unused sanity check across
  all 8 skills.

## [1.0.0] — 2026-06-29

Initial release. Eight installable skills (one auto-router, seven
runtime-specific) plus helpers and adapters, conforming to the
[agentskills.io](https://agentskills.io/specification) open standard.

- Skills: `delegate-to-any`, `delegate-to-opencode`, `delegate-to-pi`,
  `delegate-to-mimo`, `delegate-to-hermes`, `delegate-to-kimi`,
  `delegate-to-codex`, `delegate-to-agy`.
- Shared workflow in `skills/shared/workflow.md` (Steps −1 through 5).
- Helpers: `helpers/scripts/delegate.sh` (portable launcher),
  `helpers/adapters/generic-prompt.md` (universal prompt template),
  `helpers/hermes/delegate-tasks/SKILL.md` (hermes-native skill).
- 402-assertion structure test suite.

[1.2.0]: https://github.com/bassemZohdy/delegate-skills/releases/tag/v1.2.0
[1.1.0]: https://github.com/bassemZohdy/delegate-skills/releases/tag/v1.1.0
[1.0.0]: https://github.com/bassemZohdy/delegate-skills/releases/tag/v1.0.0
