# Changelog

All notable changes to this project are documented here. Versions correspond to
the `metadata.version` field in each skill's `SKILL.md`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
