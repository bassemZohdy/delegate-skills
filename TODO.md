# Task Ledger

Append-only. Never delete or rewrite existing `## [TASK-N]` blocks — only update fields within them.

See `docs/workflow.md` for the full field schema and status lifecycle.

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
