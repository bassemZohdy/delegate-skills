# Task Ledger

Append-only. Never delete or rewrite existing `## [TASK-N]` blocks — only update fields within them.

See `docs/workflow.md` for the full field schema and status lifecycle.

## [TASK-1] Fix omo launch block missing worktree isolation
- status: in_progress
- owner: reviewer/2026-06-30T00:00:00Z
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
- [ ] Add --dir "$WORK_DIR" (or help-checked fallback) to omo block in delegate-to-opencode/SKILL.md
- [ ] Mirror the fix in delegate-to-any/SKILL.md omo block

### Verification
- `grep -A8 'omo.*oh-my-opencode' skills/delegate-to-opencode/SKILL.md` shows --dir or WORK_DIR usage
- Same for delegate-to-any/SKILL.md
- `bash tests/run-tests.sh` passes

## [TASK-2] Fix stale PID in delegate.sh cd-based runtimes
- status: in_progress
- owner: reviewer/2026-06-30T00:00:00Z
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
- [ ] Restructure cd-based runtimes so TASK_PID=$! is the agent process, not the wrapping subshell
- [ ] Also initialize .retries file for parity with SKILL.md inline blocks
- [ ] Fix duplicated `2>/dev/null 2>/dev/null` on the git rev-parse preflight line

### Verification
- `grep -n 'TASK_PID=\$!' helpers/scripts/delegate.sh` appears once per runtime case and refers to nohup, not a `( ... ) &` subshell
- `grep -n 'retries' helpers/scripts/delegate.sh` shows the .retries file is written
- `bash tests/run-tests.sh` passes

## [TASK-3] Kill watchdog on normal completion in shared workflow Case 4
- status: in_progress
- owner: reviewer/2026-06-30T00:00:00Z
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
- [ ] Add watchdog kill step to Case 4 "If verification passes" branch
- [ ] Apply the same on Case 3/verification-fail terminal states where appropriate

### Verification
- `grep -n 'watchdog' skills/shared/workflow.md` shows the watchdog is killed on completion
- `bash tests/run-tests.sh` passes
