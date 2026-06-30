# Changelog

All notable changes to this project are documented here. Versions correspond to
the `metadata.version` field in each skill's `SKILL.md`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[1.1.0]: https://github.com/bassemZohdy/delegate-skills/releases/tag/v1.1.0
[1.0.0]: https://github.com/bassemZohdy/delegate-skills/releases/tag/v1.0.0
