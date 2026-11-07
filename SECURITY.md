# Security

## What this project does

`delegate-skills` ships eight skills and one bash launcher (`helpers/scripts/delegate.sh`, copied into every skill as `scripts/delegate.sh`). The launcher starts another agent CLI (opencode, pi, mimo, hermes, kimi, codex or agy) as a background process in a git worktree, records its PID and exit code under `.delegate/`, and can stop it. It does not use the network itself. The agent CLIs it starts do.

## Threat model

- **A delegated agent runs with your user's permissions.** A git worktree separates code edits. It is not a security boundary: the agent can read your environment variables and files and use the network, and it shares the repository's `.git` metadata. Use an external sandbox (container, VM, restricted user) when you need those limits.
- **Permission bypass is opt-in per launch.** `DELEGATE_ALLOW_UNSAFE_FLAGS=1` adds each runtime's skip-permissions flag. `DELEGATE_ALLOW_UNISOLATED=1` lets the agent edit the original checkout when no worktree can be made. Neither is ever inferred, and both accept only `0` or `1`.
- **Task text is untrusted input.** The handoff document and `TODO.md` entries are passed to the agent. Anything an agent can be told to do, a malicious handoff can ask for. Review handoffs from untrusted sources before launching.
- **Guards against accidents, not attackers.** Task IDs must be `TASK-N`; timeouts must be positive integers; `.delegate/` paths may not be symlinks; an existing worktree must belong to this repository and branch `<runtime>/TASK-N`. These stop accidental traversal and reuse, and do not defend against a hostile process that changes paths after the check.
- **Stopping is best effort.** `stop` and the timeout signal the agent's descendants, its process group when it leads one, and the agent. A PID-reuse fingerprint check refuses to signal a PID that no longer matches.

## Review status

Reviewed on 2026-11-07 for the 1.4.0 launcher:

- `shellcheck` 0.11.0 reports no findings at warning level on `helpers/scripts/delegate.sh`.
- The generated supervisor script (`.delegate/tasks/TASK-N.supervisor.sh`) builds every value it embeds with `printf '%q'`, and the agent command lines are assembled as arrays and quoted the same way. The handoff markdown is never expanded into a shell variable.
- No `eval`, `sh -c` or world-writable temp files are used. State lives under `.delegate/`, which is excluded from `git status` through `info/exclude`.
- No high-severity finding was open at review time. This is a manual review plus static analysis, not an external audit. The behavior and safety suites (`bash tests/run-tests.sh`) run on Ubuntu and Windows Git Bash in CI.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting on this repository ("Security" tab, "Report a vulnerability"). Include the runtime, the command you ran, what happened, and the script or skill text involved. You can expect an acknowledgement within a week.
