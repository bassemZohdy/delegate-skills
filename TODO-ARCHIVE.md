# Task Ledger Archive

Completed task blocks moved out of `TODO.md` to keep the active ledger short.
History preserved verbatim — see `skills/shared/workflow.md` for the field
schema and status lifecycle. Nothing here is append-only in the same sense as
`TODO.md`; this file is a historical record, not an active queue.

## [TASK-1] Fix omo launch block missing worktree isolation
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 573001b
- dirty_tree: false
- handoff: none
- output_ref: skills/delegate-to-opencode/SKILL.md, skills/delegate-to-any/SKILL.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Editing the omo launch blocks in delegate-to-opencode/SKILL.md and delegate-to-any/SKILL.md to add --dir/worktree handling.

### Sub-tasks
- [x] Add --dir "$WORK_DIR" (or help-checked fallback) to omo block in delegate-to-opencode/SKILL.md
- [x] Mirror the fix in delegate-to-any/SKILL.md omo block

### Verification
- `grep -A8 'omo.*oh-my-opencode' skills/delegate-to-opencode/SKILL.md` shows --dir or WORK_DIR usage
- Same for delegate-to-any/SKILL.md
- `bash tests/run-tests.sh` passes

## [TASK-2] Fix stale PID in delegate.sh cd-based runtimes
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 573001b
- dirty_tree: false
- handoff: none
- output_ref: helpers/scripts/delegate.sh
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Refactoring pi/hermes/kimi/mimo case branches in helpers/scripts/delegate.sh so $! captures the nohup agent PID, not a subshell PID.

### Sub-tasks
- [x] Restructure cd-based runtimes so TASK_PID=$! is the agent process, not the wrapping subshell
- [x] Also initialize .retries file for parity with SKILL.md inline blocks
- [x] Fix duplicated `2>/dev/null 2>/dev/null` on the git rev-parse preflight line

### Verification
- `grep -n 'TASK_PID=\$!' helpers/scripts/delegate.sh` appears once per runtime case and refers to nohup, not a `( ... ) &` subshell
- `grep -n 'retries' helpers/scripts/delegate.sh` shows the .retries file is written
- `bash tests/run-tests.sh` passes

## [TASK-3] Kill watchdog on normal completion in shared workflow Case 4
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 573001b
- dirty_tree: false
- handoff: none
- output_ref: skills/shared/workflow.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Editing Case 4 (verification passes) in skills/shared/workflow.md to kill the lingering watchdog PID.

### Sub-tasks
- [x] Add watchdog kill step to Case 4 "If verification passes" branch
- [x] Apply the same on Case 3/verification-fail terminal states where appropriate

### Verification
- `grep -n 'watchdog' skills/shared/workflow.md` shows the watchdog is killed on completion
- `bash tests/run-tests.sh` passes

## [TASK-4] Fix Codex retry (no message) + initial launch framing
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 7172a26
- dirty_tree: false
- handoff: none
- output_ref: skills/delegate-to-codex/SKILL.md, helpers/scripts/delegate.sh
- retries: 0
- depends_on: [TASK-2]
- blocked_by: []

### Active Form
Editing Codex launch + retry blocks to pipe a framing instruction (initial) and a continuation prompt (retry) via stdin.

### Sub-tasks
- [x] Initial launch: prepend framing line via printf before the handoff in stdin (delegate-to-codex + delegate.sh)
- [x] Retry: pipe a continuation message via stdin to `codex exec resume --last`

### Verification
- `awk '/^### Launch/,/^### Retry/' skills/delegate-to-codex/SKILL.md | grep -q "Execute the task described in the handoff document below"`
- `awk '/^### Retry/,EOF' skills/delegate-to-codex/SKILL.md | grep -qE 'printf.*Continue the task|resume --last.*-''`
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-5] Dedup delegate-to-any launch logic
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 7172a26
- dirty_tree: false
- handoff: none
- output_ref: skills/delegate-to-any/SKILL.md
- retries: 0
- depends_on: [TASK-1]
- blocked_by: []

### Active Form
Replacing the eight inline launch blocks in delegate-to-any with a reference to delegate-to-<runtime>/SKILL.md + delegate.sh, keeping one common skeleton.

### Sub-tasks
- [x] Remove duplicated per-runtime launch blocks
- [x] Reference per-runtime skills + delegate.sh as the source of truth
- [x] Keep one common-skeleton block for the auditable shared mechanics

### Verification
- `grep -cE 'nohup (opencode|pi|mimo|hermes|kimi|agy) (run|chat|-p)' skills/delegate-to-any/SKILL.md` <= 1
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-6] Ensure .opencode/tasks/ exists before launch
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 7172a26
- dirty_tree: false
- handoff: none
- output_ref: skills/shared/workflow.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Adding explicit mkdir -p .opencode/tasks .opencode/worktrees to Step 3 of the shared workflow.

### Sub-tasks
- [x] Add mkdir step to shared/workflow.md Step 3

### Verification
- `grep -A4 '## Step 3' skills/shared/workflow.md | grep -q 'mkdir -p'`
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-7] Document TODO.md locking limitation
- status: completed
- owner: (cleared)
- reviewed: 2026-06-30T00:00:00Z
- agent: review / default
- started: 2026-06-30T00:00:00Z
- worktree: none
- branch: none
- base_sha: 7172a26
- dirty_tree: false
- handoff: none
- output_ref: skills/shared/workflow.md, AGENTS.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Documenting the no-lock parallel-delegation hazard in TODO.md Conventions + AGENTS.md Known gotchas.

### Sub-tasks
- [x] Add locking note to shared/workflow.md TODO.md Conventions
- [x] Add gotchas for locking, watchdog cancellation, codex framing/retry, and mkdir to AGENTS.md

### Verification
- `grep -qi 'no lock' skills/shared/workflow.md`
- `grep -qi 'no lock\|watchdog must be cancelled\|must exist before launch' AGENTS.md`
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-8] Fix stale docs/workflow.md references
- status: completed
- owner: (cleared)
- reviewed: 2026-07-03T00:00:00Z
- agent: review / default
- started: 2026-07-03T00:00:00Z
- worktree: none
- branch: none
- base_sha: 895f3de
- dirty_tree: false
- handoff: none
- output_ref: helpers/scripts/delegate.sh, TODO.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Fixing two leftover references to docs/workflow.md left over from the v1.1.0 restructure that moved the shared workflow doc to skills/shared/workflow.md.

### Sub-tasks
- [x] Fix error-message path in helpers/scripts/delegate.sh preflight check
- [x] Fix preamble reference in TODO.md

### Verification
- `grep -rn "docs/workflow.md" helpers/scripts/delegate.sh TODO.md` returns nothing
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-9] Add scripts/delegate.sh existence guard in delegate-to-any
- status: completed
- owner: (cleared)
- reviewed: 2026-07-03T00:00:00Z
- agent: review / default
- started: 2026-07-03T00:00:00Z
- worktree: none
- branch: none
- base_sha: 895f3de
- dirty_tree: false
- handoff: none
- output_ref: skills/delegate-to-any/SKILL.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Adding an existence check around the "preferred" scripts/delegate.sh launch path in delegate-to-any/SKILL.md so it falls back to the direct per-runtime launch path when the script hasn't been copied into the target project, matching the pattern already used in helpers/adapters/generic-prompt.md and the Hermes adapter.

### Sub-tasks
- [x] Wrap the `bash scripts/delegate.sh ...` invocation in an `[ -f scripts/delegate.sh ]` check
- [x] Document the fallback to path 2 (direct launch) when the script is absent

### Verification
- `grep -A2 'if \[ -f scripts/delegate.sh' skills/delegate-to-any/SKILL.md` shows the guard
- `bash tests/run-tests.sh` passes (420/420)

## [TASK-10] Add behavioral test layer for delegate.sh
- status: completed
- owner: (cleared)
- reviewed: 2026-07-03T14:37:08Z
- agent: review / default
- started: 2026-07-03T14:37:08Z
- worktree: none
- branch: none
- base_sha: 8aa139bfcba8209f681add8bb421de4107fb9562
- dirty_tree: false
- handoff: none
- output_ref: tests/test-behavior.sh, tests/fixtures/mock-bin/
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Building a mock-CLI-based behavioral test layer that actually executes helpers/scripts/delegate.sh in isolated sandboxes, since the existing structure tests only grep-match text and can't verify runtime correctness (the skills/*/SKILL.md files are natural-language AI instructions, not executable, so delegate.sh is the only artifact that can be tested by real execution).

### Sub-tasks
- [x] Add mock CLI binaries for all 7 runtimes (tests/fixtures/mock-bin/)
- [x] Add 16 behavioral test cases covering happy paths, error paths, PID-capture regression (pi/hermes/kimi), mimo flag-detection branches, codex stdin framing, and watchdog SIGTERM firing
- [x] Fix a process-leak bug found during verification — the watchdog subshell delegate.sh always spawns was not being killed by test cleanup, leaking `sleep 30`/`sleep 120` processes on the host after every run
- [x] Fix a flaky test caused by an off-by-10x timeout bug in a wait-for-file helper
- [x] Validate via mutation testing: temporarily reintroduced the v1.1.0 subshell-PID bug into delegate.sh's `pi` case and confirmed the new test failed; restored and confirmed it passed again

### Verification
- `bash tests/run-tests.sh` passes (436/436), run 6+ times in a row with zero failures
- `bash tests/test-behavior.sh` passes standalone
- `ps ax | grep -E 'sleep 30|sleep 120|mock-bin'` shows nothing after a full suite run (no leaked processes)
- Mutation test: reverting the pi-case fix in delegate.sh causes exactly the pi-specific regression tests to fail (both the pre-existing structure-level one and the new behavioral one) and nothing else

## [TASK-11] Create a testing file called hello-world.txt
- status: completed
- owner: (cleared)
- reviewed: 2026-07-03T15:01:33Z
- outcome: hello-world.txt created in worktree with content "hello world"; verification passed
- agent: opencode / default
- started: 2026-07-03T14:59:02Z
- timeout: 300
- worktree: .opencode/worktrees/TASK-11
- branch: opencode/TASK-11
- base_sha: 54642ca320996aa43dd97c31230da586817455cf
- dirty_tree: false
- handoff: .opencode/tasks/TASK-11.md
- output_ref: hello-world.txt
- retries: 1
- depends_on: []
- blocked_by: []
- note: retry 1 — initial launch failed ("File not found: .opencode/tasks/TASK-11.md"); --file path was project-root-relative but --dir pointed opencode at the worktree checkout, which has no .opencode/tasks/ dir. Fixed by passing an absolute path to --file. Also: skills/delegate-to-opencode/SKILL.md's launch block references --dangerously-skip-permissions, which does not exist in installed opencode v1.17.13 (actual flag: --auto) — used --auto instead.

### Active Form
hello-world.txt being created at the repo root of the worktree.

### Sub-tasks
- [x] Create hello-world.txt at the project root with placeholder test content

### Verification
- `test -f hello-world.txt` succeeds in the worktree — PASS
- File is non-empty — PASS

## [TASK-12] Fix opencode stale flag, relative --file path, and worktree/TODO.md ordering bugs
- status: completed
- owner: (cleared)
- reviewed: 2026-07-03T15:18:40Z
- outcome: fixed 3 real bugs found via TASK-11's live smoke test; bumped all 8 skills to v1.2.1
- agent: review / default
- started: 2026-07-03T15:18:40Z
- worktree: none
- branch: none
- base_sha: 54642ca320996aa43dd97c31230da586817455cf
- dirty_tree: false
- handoff: none
- output_ref: skills/delegate-to-opencode/SKILL.md, skills/delegate-to-mimo/SKILL.md, skills/delegate-to-any/SKILL.md, skills/shared/workflow.md, helpers/scripts/delegate.sh, helpers/adapters/generic-prompt.md, helpers/hermes/delegate-tasks/SKILL.md, docs/usage.md, CHANGELOG.md
- retries: 0
- depends_on: []
- blocked_by: []

### Active Form
Editing launch blocks to detect opencode's auto-approval flag dynamically, making --file paths absolute under --dir, and reordering workflow.md Steps 1/2 so TODO.md is committed before the worktree is created.

### Sub-tasks
- [x] Fix stale `--dangerously-skip-permissions` → dynamic detection (`--auto` or `--dangerously-skip-permissions`) in delegate-to-opencode, delegate-to-any, helpers/scripts/delegate.sh, helpers/adapters/generic-prompt.md, helpers/hermes/delegate-tasks/SKILL.md
- [x] Fix relative `--file` path under `--dir` in delegate-to-opencode (both opencode and omo blocks), delegate-to-mimo
- [x] Reorder shared workflow.md Step 1 (was worktree) / Step 2 (was TODO.md) so the ledger entry is committed before the worktree branches from it; same reorder applied to the two alternate-format docs
- [x] Add TODO.md commit points to Step 5 Case 4 (completion) without automating the worktree merge itself
- [x] Bump metadata.version to 1.2.1 across all 8 skills, add CHANGELOG.md entry
- [x] Run full test suite to confirm no regressions
- [x] Caught own regression: the delegate.sh flag-detection fix hung under `MOCK_HANG=1` (mock had no `--help` short-circuit) and broke 2 tests that don't set `MOCK_OUT_DIR`. Fixed both mock binaries (opencode, mimo) to handle `--help` before any env requirement; updated the one test assertion that hardcoded the removed opencode flag
- [x] Cleaned up TASK-11's worktree, branch, and gitignored runtime scratch files (smoke test already fully documented; not merged — trivial throwaway output)

### Verification
- `bash tests/run-tests.sh` passes 436/436, run 4 times in a row with zero failures
- `ps ax | grep -E 'sleep 30|sleep 120|mock-bin'` shows nothing after a full suite run (no leaked processes)
- `grep -rn "dangerously-skip-permissions" skills/ helpers/` shows only dynamic-detection occurrences, no unconditional hardcoded use for opencode
- `grep -n "^## Step" skills/shared/workflow.md` shows Step 1 = Update TODO.md, Step 2 = Create Worktree
- `git worktree list` shows no `TASK-11` entry; `git branch -a` shows no `opencode/TASK-11`
