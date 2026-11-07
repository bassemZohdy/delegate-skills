# Task Ledger

Append-only. Never delete or rewrite existing `## [TASK-N]` blocks — only update fields within them.

See `skills/shared/workflow.md` for the full field schema and status lifecycle.
Completed tasks TASK-1 through TASK-12 have been moved to `TODO-ARCHIVE.md` to
keep this file focused on active work — see that file for full history.

TASK-13 … TASK-26 are the backlog from the 2026-11-06 full-project review
(filed against the staged, uncommitted 1.4.0 tree on top of `dcc8504`).
`status: pending` = not picked up yet; set `owner` and `status: in_progress`
when starting one. Priorities: P1 = breaks a documented path, P2 = wrong result
or missing safeguard, P3 = improvement.

## [TASK-13] Timeout and stop leave the agent's child processes alive when no process group exists (Windows, macOS)
- status: completed
- priority: P1
- owner: (cleared)
- reviewed: 2026-11-06T11:05:00Z
- outcome: `_descendants`/`_signal_descendants` (ps-table walk, deepest first) used by `stop` and by the supervisor's timer; launch now fails instead of printing PID=unknown; two grandchild tests pass on Windows
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T10:50:00Z
- timeout: 1800
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, tests/test-behavior.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
The supervisor's timer (`helpers/scripts/delegate.sh:629-644`, `signal_agent`) signals the process group only when launch verified a pgid, otherwise just `$RUNTIME_PID`. A pgid is only ever verified when `setsid` exists (`delegate.sh:418-419`) — it does not on Git Bash/MSYS or stock macOS. Reproduced on Windows: a `kimi` wrapper that runs the real agent as a child, timeout 2 s → `status` says `TIMED_OUT`, the wrapper is dead, the real agent is still running (`kill -0` succeeds). Any CLI that spawns its engine as a child (npm shim without `exec`, node spawning a worker, the agent's own shells/test runners) survives a timeout on those platforms. `kill_tree` (`delegate.sh:262-275`) used by `stop` only scans one level of children, so grandchildren (agent → shell → `npm test`) survive `stop` everywhere.

### Active Form
`signal_agent` in the generated supervisor and `kill_tree` share one recursive descendant-kill helper; a new behavior test launches a two-level mock and asserts the leaf process is gone after a timeout and after `stop`.

### Sub-tasks
- [x] Add `_descendants PID` (depth-first: `pkill`-free; `ps -eo pid=,ppid=` with the `_ps_children_fixed` MSYS fallback) and make `kill_tree` signal deepest-first, then the pgid when verified, then the PID
- [x] Export it like `_ps_fixed_field` (`delegate.sh:661`) and call it from the supervisor's `signal_agent` for both TERM and KILL
- [x] Launch must not print `PID=unknown` and exit 0 when the supervisor never records a PID within the wait window (`delegate.sh:675-682`): fail (exit 1) and kill the supervisor, otherwise `status` → `NOT_FOUND` → the workflow's "launch it" row starts a second agent
- [x] Behavior test: wrapper mock whose child is the heartbeat mock; after timeout and after `stop`, the child's pid (from `MOCK_OUT_DIR/*.pid`) must be dead; run on Windows and Ubuntu CI
- [x] Update AGENTS.md "Process-group kill" bullet and docs/usage.md "Killing a stalled or timed-out process" paragraph

### Verification
```bash
bash tests/run-tests.sh
grep -n '_descendants' helpers/scripts/delegate.sh
bash helpers/scripts/sync-skills.sh --check
```

## [TASK-14] `omo` branch label makes the launcher refuse to launch (worktree/branch mismatch)
- status: completed
- priority: P1
- owner: (cleared)
- reviewed: 2026-11-06T11:45:00Z
- outcome: branch is always `<launcher-runtime>/TASK-N`; `omo` is only the TODO.md `agent:` label (workflow.md Step 1/2, delegate-to-any, delegate-to-opencode); structure test forbids `omo/TASK` in distributed files
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:32:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: skills/delegate-to-any/SKILL.md, skills/delegate-to-opencode/SKILL.md, skills/shared/workflow.md
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
`delegate-to-any` tells the model to label oh-my-opencode tasks `omo` "in TODO.md and on the worktree branch name" (`skills/delegate-to-any/SKILL.md:121,161`) and workflow Step 2 creates `git worktree add … -b $RUNTIME/TASK-N` with `RUNTIME=omo` (`skills/shared/workflow.md:158-159`). The launcher then runs as `opencode` and requires branch `opencode/TASK-N` (`delegate.sh:385`, `validate_worktree`). Reproduced: worktree on `omo/TASK-1` + `delegate.sh opencode TASK-1` → `ERROR: existing worktree must belong to this repository and branch opencode/TASK-1.` Every omo delegation through the documented preferred path is refused.

### Active Form
The branch name is always `<launcher-runtime>/TASK-N`; `omo` survives only as the `agent:` label in TODO.md; the three files agree.

### Sub-tasks
- [x] workflow.md Step 2: drop `omo` from the `RUNTIME=` list and state that the branch must use the binary name passed to the launcher
- [x] delegate-to-any: "label the task `omo`" applies to the `agent:` field only; branch stays `opencode/TASK-N`
- [x] delegate-to-opencode: same note next to the `omo` manual block; the manual omo block must create/use `opencode/TASK-N`
- [x] Structure test: no distributed file may say the branch is `omo/TASK-N`
- [x] Re-sync (`bash helpers/scripts/sync-skills.sh`)

### Verification
```bash
! grep -rn 'omo/TASK' skills/ helpers/ docs/ README.md
bash tests/run-tests.sh
```

## [TASK-15] `status` reports LAUNCH_FAILED instead of STOPPED/TIMED_OUT when the supervisor died before writing `.exitcode`
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-06T11:30:00Z
- outcome: markers checked before the exit code; `EXITCODE=` printed only when known; watchdog.pid comment points at `stop`; test_status_markers_without_exitcode
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:10:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, tests/test-behavior.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
The `.stopped` / `.timedout` checks sit inside `if [ -f "$EXITCODE_FILE" ]` (`delegate.sh:753-775`). If the supervisor was killed (session teardown, `kill $(cat TASK-N.watchdog.pid)` as the header comment at `delegate.sh:68-70` still suggests) the exit code is never written and a deliberately stopped or timed-out task is classified by log size: reproduced `STATE=LAUNCH_FAILED` with a `.stopped` marker and a dead pid — which the workflow treats as Case 1 and relaunches.

### Active Form
Marker files are checked before the exit-code branch; `EXITCODE=` is printed only when known; the header comment points at `delegate.sh stop`.

### Sub-tasks
- [x] Reorder: `TIMED_OUT` / `STOPPED` first (with `EXITCODE=` if the file exists), then exit-code classes, then the no-exit-code fallback
- [x] Fix the `TASK-N.watchdog.pid` comment ("kill this to force-abandon" leaves the agent and timer running) → "use `delegate.sh stop`"
- [x] Behavior test: dead pid + marker, no `.exitcode` → `STATE=STOPPED` / `STATE=TIMED_OUT`
- [x] docs/usage.md state list unchanged; AGENTS.md "Timeout / stop markers" bullet mention the ordering

### Verification
```bash
bash tests/run-tests.sh
```

## [TASK-16] Relaunch fails after a worktree directory was deleted without `git worktree prune`
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-06T11:30:00Z
- outcome: launch prunes before `git worktree add` and reports git's own error; test_relaunch_after_worktree_deleted; docs/install.md + workflow.md Step 2 note
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:10:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, tests/test-behavior.sh, skills/shared/workflow.md
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
`git worktree add` refuses a path that is "missing but already registered" (`git worktree list` shows it `prunable`). `delegate.sh:389-397` tries `-b BRANCH` then `BRANCH` and reports `worktree creation failed — refusing to launch without worktree isolation`. Reproduced after `rm -rf .delegate/worktrees/TASK-2`. A user cleaning up by hand (or a crashed disk) then cannot resume the task at all, and the error message blames isolation.

### Active Form
Launch runs `git worktree prune` before creating a worktree and reports the real git error on failure.

### Sub-tasks
- [x] Call `git worktree prune` (quiet) when `$WORK_DIR` does not exist, before `git worktree add`
- [x] Capture git's stderr from both `worktree add` attempts and include the last line in the ISOLATION_FAILURE message
- [x] Behavior test: launch, remove the worktree dir, relaunch → exit 0, branch reused
- [x] workflow.md Step 2 / docs/install.md "Worktree creation fails" troubleshooting: mention prune

### Verification
```bash
bash tests/run-tests.sh
```

## [TASK-17] Stall detection never fires in unisolated mode (status's own files count as worktree activity)
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-06T11:30:00Z
- outcome: the activity scan prunes `.delegate` and `.git`; test_status_stalled covers worktree and unisolated modes (RUNNING → STALLED → RUNNING after a write)
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:10:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, tests/test-behavior.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
With `DELEGATE_ALLOW_UNISOLATED=1`, `WORK_DIR` is the project root, so the `find "$WORK_DIR" -newer lastpoll` scan (`delegate.sh:725-736`) sees `.delegate/tasks/TASK-N.log.size`, written by `status` itself one line earlier (`delegate.sh:717`), and the growing log. Reproduced: hung mock writing nothing, four polls → `RUNNING` every time, never `STALLED`, so Case 2 never triggers. There is also no behavior test for `STALLED` at all.

### Active Form
`find` prunes `.delegate` and `.git`; a behavior test proves `STALLED` on the second poll for a silent agent (worktree and unisolated).

### Sub-tasks
- [x] Add `-path "$WORK_DIR/.delegate" -prune -o -path "$WORK_DIR/.git" -prune -o … -type f -newer … -print` to the scan
- [x] Behavior test: `MOCK_HANG=1` with `MOCK_OUT_DIR` outside the sandbox; poll twice → `STALLED`; then a file written in the worktree → `RUNNING`
- [x] Same test in unisolated mode

### Verification
```bash
bash tests/run-tests.sh
```

## [TASK-18] `next-id` stale-lock self-heal is silently disabled on macOS (`date -r` is BSD "seconds", not "file")
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-06T11:30:00Z
- outcome: `_mtime_epoch` (stat -c → stat -f → date -r) backs the staleness check; test_next_id_reclaims_stale_lock; no other GNU-only coreutils flags found in the launcher (`date -r`, `readlink -f`, `sed -i`, `sort -V` absent)
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:10:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
`delegate.sh:888` uses `date -r "$LOCK_DIR" +%s` (GNU: mtime of a file). BSD/macOS `date -r` takes seconds since the epoch, so it errors, `mtime=""`, and the 30 s staleness check is skipped: a lock left by a crashed process is never removed and every later `next-id` fails after 10 s with "remove … manually". CI only runs Ubuntu and Windows (both GNU coreutils), so this is untested.

### Active Form
Lock age is computed with a portable helper (`stat -c %Y` → `stat -f %m` → `find -mmin` fallback); a unit test fakes an old lock dir and expects it to be reclaimed.

### Sub-tasks
- [x] Add `_mtime_epoch PATH` with GNU/BSD `stat` fallbacks; use it in `cmd_next_id`
- [x] Behavior test: pre-create `.delegate/todo.lock` with `touch -d '-60 seconds'` (or `-t`) → `next-id` succeeds and the lock is gone afterwards
- [x] Grep the launcher for other GNU-only invocations (`date -r`, `readlink -f`, `sed -i`) and note macOS in AGENTS.md "Known gotchas"

### Verification
```bash
bash tests/run-tests.sh
! grep -n 'date -r' helpers/scripts/delegate.sh
```

## [TASK-19] CI: lint shell and workflow files (shellcheck, actionlint)
- status: in_progress
- priority: P2
- owner: claude-code/2026-11-07T10:00:00Z
- outcome-so-far: `lint` job in test.yml (shellcheck -S warning with 5 documented exclusions, actionlint 1.7.7 via docker); supervisor `bash -n` in test_opencode_happy. Awaiting first CI run to confirm shellcheck is clean.
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T09:40:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: .github/workflows/test.yml
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
`delegate.sh` carries a `# shellcheck disable=SC2086` (`delegate.sh:184`) but nothing runs shellcheck; the generated supervisor script, four test scripts and `sync-skills.sh` are unlinted, and the two new workflow files were never checked by actionlint (blocked locally). The bugs in TASK-13/15/18 are the kind shellcheck/CI linting surfaces early.

### Active Form
A `lint` job in `test.yml` runs shellcheck over every `*.sh` (plus the mock-bin fixtures) and actionlint over `.github/workflows/*.yml`; findings fixed or explicitly disabled with a reason.

### Sub-tasks
- [ ] Add a `lint` job (ubuntu) pinned by commit: `ludeeus/action-shellcheck` or `apt-get install shellcheck`, and `rhysd/actionlint`
- [ ] Fix or justify every shellcheck finding in `helpers/scripts/*.sh`, `tests/*.sh`, `tests/fixtures/mock-bin/*`
- [ ] Add `bash -n` of the generated supervisor to a behavior test (write it with a mock, then `bash -n TASK-N.supervisor.sh`)
- [ ] README "Running tests": mention the lint job

### Verification
```bash
shellcheck helpers/scripts/delegate.sh helpers/scripts/sync-skills.sh tests/*.sh
bash tests/run-tests.sh
```

## [TASK-20] Docs: dead runtime links, stale repo tree, Hermes path, launcher phrasing, pi install command
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-07T08:30:00Z
- outcome: README runtime links use curl-verified URLs; repo tree lists .github/ and the new tests; Hermes quick start resolves HERMES_HOME; all 8 skills say "bundled launcher ($DELEGATE_SH)"; pi install is npm everywhere; three structure checks pin it
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T08:05:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: README.md, docs/usage.md, docs/install.md, skills/delegate-to-*/SKILL.md, helpers/scripts/delegate.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
- README runtime table (`README.md:29-35`): `https://hermes.agent` and `https://earendil.works` do not resolve; `https://agy.dev` only redirects. `.github/upstream-sources.yml` has the real URLs (github.com/NousResearch/hermes-agent, pi.dev, antigravity.google).
- README repo tree (`README.md:183-224`) omits `.github/` (manifest + 3 workflows), `tests/test-upstream.sh`, `tests/check-cli-contract.py`, `TODO-ARCHIVE.md`, `CHANGELOG.md`.
- README Hermes quick start (`README.md:111`) hardcodes `~/.hermes/skills/...`; docs/install.md:190-213 says to resolve `HERMES_HOME` first (Windows default differs).
- All 8 SKILL.md "Safety defaults" open with "Prefer the tested launcher (`scripts/delegate.sh` when installed in the project)" — the launcher is bundled since 1.4.0 and the workflow resolves `$DELEGATE_SH`.
- pi install: README, docs/usage.md:9, `delegate.sh:357`, delegate-to-any:66 and the Hermes helper say `bun install -g`; `.github/upstream-sources.yml` and `cli-contract.yml` use `npm install -g` (the package is on npm).

### Active Form
Links verified with curl, one install command per runtime everywhere, repo tree regenerated, Hermes snippet uses `${HERMES_HOME:-$HOME/.hermes}`, the launcher sentence reads "Prefer the bundled launcher (`$DELEGATE_SH`)".

### Sub-tasks
- [x] README links → manifest URLs; offline structure test forbids the known-dead domains
- [x] Regenerate the README tree; add `.github/` section
- [x] Hermes quick start → HERMES_HOME form
- [x] Replace the launcher sentence in the 8 skills (and `.agents` mirror via sync)
- [x] Pick `npm install -g @earendil-works/pi-coding-agent` and apply it everywhere, including `delegate.sh`'s not-found hint

### Verification
```bash
for u in $(grep -oE 'https://[^) ]+' README.md | sort -u); do curl -s -o /dev/null -L -w "%{http_code} $u\n" "$u"; done | grep -v '^200'
! grep -rn 'when installed in the project' skills/
bash tests/run-tests.sh
```

## [TASK-21] Decide: launch policy for runtimes that cannot keep tool approvals (kimi ≥ 2 print mode, pi)
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-07T08:00:00Z
- outcome: owner chose (a) warn-and-launch; pi now warns on every launch like kimi >= 2; README/usage state the limitation; tests for both opt-in modes
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T07:50:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, docs/usage.md, AGENTS.md
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
The safety contract says bypass is opt-in via `DELEGATE_ALLOW_UNSAFE_FLAGS=1`, but two runtimes never prompt regardless: kimi-code ≥ 2 `-p` is auto-permission and rejects `-y` (`delegate.sh:513-525` warns), and pi has no per-tool approvals at all (`delegate.sh:464-476`). Today both launch with only a WARN on stderr, so a "safe default" launch still runs arbitrary commands. Needs an owner decision (asked twice, unanswered): (a) keep warn-and-launch, (b) require `DELEGATE_ALLOW_UNSAFE_FLAGS=1` for these two, or (c) add a third opt-in `DELEGATE_ALLOW_NO_APPROVALS=1`.

### Active Form
Decision recorded here; launcher, safety tests (`tests/test-safety.sh` kimi2/pi cases), docs/usage.md "Launch safety" and README updated to match.

### Sub-tasks
- [x] Owner picks (a)/(b)/(c) and records it in this block — owner chose (a) warn-and-launch
- [x] Implement in `cmd_launch` for kimi (version-gated) and pi
- [x] Safety tests assert the chosen behavior for mode 0 and 1
- [x] Document in docs/usage.md, README "Launch safety", AGENTS.md gotchas (AGENTS.md already carries the kimi/pi gotchas)

### Verification
```bash
bash tests/run-tests.sh
grep -n 'NO_APPROVALS\|never asks for approval' helpers/scripts/delegate.sh
```

## [TASK-22] Verify the oh-my-opencode CLI surface or drop the `omo` manual path
- status: completed
- priority: P2
- owner: (cleared)
- reviewed: 2026-11-06T11:45:00Z
- outcome: (a) — `oh-my-opencode run <message>` exists (oh-my-openagent 5.1.62 docs/reference/cli.md, read via gh api; npx execution was blocked): flags are -d/--directory, -m/--model, --session-id; no --file/--dir/--continue/--yes. Manual block rewritten to those flags (absolute handoff path in the message, cd + --directory), retry note via launcher --continue, structure test pins the real flags, manifest `manual_only:` entry added for the AI watch
- agent: claude-code / claude-fable-5-1
- started: 2026-11-06T11:32:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: skills/delegate-to-opencode/SKILL.md, skills/delegate-to-any/SKILL.md, tests/test-structure.sh
- retries: 0
- depends_on: [TASK-14]
- blocked_by: []

### Problem
`delegate-to-opencode` ships a manual block for `oh-my-opencode run … --file … --dir … --yes` (`SKILL.md:135-188`) and `delegate-to-any` ranks the `oh-my-opencode` binary first. npm shows `oh-my-opencode` 5.1.62 is an opencode *plugin* whose bins (`oh-my-opencode`, `lazycodex`, …) are an installer/doctor CLI; nothing in this repo verifies that a `run` subcommand, `--yes`, `--file` or `--dir` exist, and the structure test (`tests/test-structure.sh:686-692`) pins that block's shape. If `run` does not exist the manual path is dead code and the priority-1 detection only serves to label tasks.

### Active Form
`oh-my-opencode --help` / `oh-my-opencode run --help` output captured and either (a) the block corrected to the real flags with a help-detected launch, or (b) the block and the `omo` priority row removed, keeping only "if the plugin is installed, `opencode` loads it".

### Sub-tasks
- [x] Run `npx -y oh-my-opencode@latest --help` (and `run --help`) in a throwaway dir; record the output in the task — execution was blocked in-session; the upstream `docs/reference/cli.md` (5.1.62) was read instead and is quoted in delegate-to-opencode
- [x] Apply (a) or (b) to delegate-to-opencode, delegate-to-any (detect list, priority table, missing_runtime JSON), AGENTS.md, docs/usage.md:30
- [x] Update the structure test's omo regression check accordingly
- [x] Add `oh-my-opencode` to `.github/upstream-sources.yml` only if (a)

### Verification
```bash
bash tests/run-tests.sh
bash helpers/scripts/sync-skills.sh --check
```

## [TASK-23] Add `delegate.sh cleanup TASK-N` for the post-merge teardown
- status: completed
- priority: P3
- owner: (cleared)
- reviewed: 2026-11-07T09:30:00Z
- outcome: `delegate.sh cleanup TASK-N [--force]`: refuses while running, refuses (removing nothing) when unmerged or dirty, keeps logs; used by workflow Case 4, usage, README, Hermes helper, generic prompt; behavior test covers running/merged/unmerged/force/nothing-to-clean
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T08:40:00Z
- timeout: 1800
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, skills/shared/workflow.md, docs/usage.md
- retries: 0
- depends_on: [TASK-16]
- blocked_by: []

### Problem
Completion ends with three manual commands (`git merge`, `git worktree remove`, `git branch -d`) repeated in workflow.md:361-365, docs/usage.md:118-122, README and the Hermes helper. There is no safe way to tear a task down: `worktree remove` on a dirty worktree fails, `branch -d` on an unmerged branch fails, and nothing refuses while the agent is still running. TASK-16 shows what a half-removed worktree does to a relaunch.

### Active Form
`cmd_cleanup`: refuses if `task_agent_alive`; `git worktree remove` (with `--force` only on `--force`); `git branch -d` (never `-D` unless `--force`); keeps `.delegate/tasks/TASK-N.*` logs; prints `STATE=CLEANED`; merge stays manual.

### Sub-tasks
- [x] Implement `cleanup <task-id> [--force]` with the same validations as `stop`
- [x] Behavior tests: refuses while running; clean after merge; refuses unmerged without `--force`
- [x] workflow.md Case 4 and docs: replace the two teardown commands with `bash "$DELEGATE_SH" cleanup TASK-N` after the user's merge
- [x] usage/README/AGENTS.md subcommand lists

### Verification
```bash
bash tests/run-tests.sh
bash helpers/scripts/delegate.sh 2>&1 | grep -q cleanup
```

## [TASK-24] `delegate.sh version` and a launcher-compatibility check for project-local pinned copies
- status: completed
- priority: P3
- owner: (cleared)
- reviewed: 2026-11-07T09:30:00Z
- outcome: `DELEGATE_VERSION` + `version` subcommand, `--help` exits 0; workflow resolver keeps the bundled launcher when a project-pinned copy is older (tested by running the real snippet); structure test ties DELEGATE_VERSION to every skill's metadata.version
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T08:40:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/scripts/delegate.sh, skills/shared/workflow.md, tests/test-behavior.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
The workflow prefers a project-local `scripts/delegate.sh` over the bundled copy (`workflow.md:14-19`), but every skill now relies on 1.4.0 subcommands (`stop`, `--continue`, `TIMED_OUT`). A project that pinned a 1.3.x launcher (docs/install.md:250-257 recommends pinning) gets `Unsupported runtime 'stop'`-style failures mid-workflow. The launcher has no version string, and `--help` exits 1 (`delegate.sh:973`).

### Active Form
`delegate.sh version` prints the semver matching `CHANGELOG.md`; the workflow's resolver prefers the bundled copy when the project-local one is older or lacks `version`; `--help` exits 0; a structure test keeps the version in sync with the skills' `metadata.version`.

### Sub-tasks
- [x] Add `DELEGATE_VERSION=1.4.x` + `version` subcommand; `-h/--help` → exit 0
- [x] workflow.md resolver: compare versions (`sort -V` fallback to string compare) and warn when overriding
- [x] Structure test: `DELEGATE_VERSION` equals every `metadata.version`
- [x] docs/install.md pinning section: mention the check

### Verification
```bash
bash helpers/scripts/delegate.sh version
bash tests/run-tests.sh
```

## [TASK-25] Spec compliance: run `skills-ref validate` in CI and settle the non-spec frontmatter fields
- status: in_progress
- priority: P3
- owner: claude-code/2026-11-07T10:00:00Z
- outcome-so-far: `spec` job in test.yml runs `skills-ref==0.1.1` on copies stripped of `disable-model-invocation`/`argument-hint` (skills-ref ALLOWED_FIELDS rejects them; they must stay top-level for Claude Code). Offline test pins the same rule. Awaiting first CI run.
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T09:40:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: .github/workflows/test.yml, skills/delegate-to-*/SKILL.md, AGENTS.md
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
All 8 skills carry `disable-model-invocation` and `argument-hint` (SKILL.md lines 10-11), which are Claude Code extensions, not agentskills.io fields. The reference validator (`agentskills/agentskills` → `skills-ref`) may reject unknown top-level keys; install was blocked in this session so it is unverified. The structure test currently *requires* both fields (`tests/test-structure.sh:250,285`). If the validator rejects them, cross-tool installs may too.

### Active Form
`pip install` of skills-ref in a CI job, `skills-ref validate skills/delegate-to-*` green; either the fields moved under `metadata:` (if rejected) or the job documents that extensions are tolerated.

### Sub-tasks
- [ ] Run `skills-ref validate` locally on one skill; record the result
- [ ] If it rejects: move both fields under `metadata.claude-code:` or drop `argument-hint`, update structure test + AGENTS.md "What this repo is"
- [ ] Add the validate step to `test.yml` (pinned version)
- [ ] upstream-watch prompt already covers spec changes; link this task from AGENTS.md

### Verification
```bash
skills-ref validate skills/delegate-to-any
bash tests/run-tests.sh
```

## [TASK-26] Hermes helper parity: ledger fields, `--continue` self-delegation claim
- status: completed
- priority: P3
- owner: (cleared)
- reviewed: 2026-11-07T09:30:00Z
- outcome: Hermes helper and generic prompt emit the full ledger/handoff field set; Rule 7 no longer suggests --continue on a first launch; structure tests pin both
- agent: claude-code / claude-sonnet-5-5
- started: 2026-11-07T08:40:00Z
- timeout: 600
- worktree: none
- branch: none
- base_sha: dcc8504e4d897a7f12085e520fadf0e4c41f034a
- dirty_tree: true
- handoff: none
- output_ref: helpers/hermes/delegate-tasks/SKILL.md, helpers/adapters/generic-prompt.md
- retries: 0
- depends_on: []
- blocked_by: []

### Problem
`helpers/hermes/delegate-tasks/SKILL.md:88` writes a TODO.md entry without `base_sha`, `dirty_tree`, `retries`, `output_ref` or an `### Active Form` section, yet Rule 5 (`:201`) and `reconcile` rely on them; `generic-prompt.md:36-50` has the same gap. Rule 7 (`:203`) tells a hermes parent to launch the child with `--continue` "so sessions don't collide" — `--continue` resumes the most recent session for the cwd, which is the opposite of a fresh child session; the launcher's `--continue` is reserved for self-healing retries.

### Active Form
Both templates emit the full field set from workflow.md Step 1 (minus nothing), Rule 7 replaced with "the child runs in the worktree cwd, so its session is separate; never pass `--continue` on a first launch".

### Sub-tasks
- [x] Align the TODO.md and handoff templates in both files with workflow.md Step 1/3
- [x] Rewrite Rule 7; structure test that neither file suggests `--continue` for a first launch
- [x] Hermes helper `version:` bumped with the next release

### Verification
```bash
grep -n 'active_form\|Active Form' helpers/hermes/delegate-tasks/SKILL.md helpers/adapters/generic-prompt.md
bash tests/run-tests.sh
```
