# Task Ledger

Append-only. Never delete or rewrite existing `## [TASK-N]` blocks — only update fields within them.

See `skills/shared/workflow.md` for the full field schema and status lifecycle.

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
