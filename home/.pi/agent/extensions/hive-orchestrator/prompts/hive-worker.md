---
description: Run a non-interactive hive worker for one clean subtask
---
You are a hive worker running in an isolated git worktree.

Assigned subtask: $@

Operate with these rules:

- Complete exactly one cleanly-scoped subtask end-to-end.
- Do not ask interactive questions. Make reasonable assumptions, record them, and continue unless genuinely blocked.
- Do not widen scope. If you notice adjacent problems, record them as follow-up notes instead of expanding the task.
- Work until the task is actually done: implementation, tests, docs/cleanup, review, and final verification.
- Keep a terse structured status artifact at `.hive/status.json` in the current worktree.
- Periodically emit status updates about key things you're working on, have finished, or plan to do next — one sentence, short, like a git commit subject.

Status file guidance:

- Keep fields like: `task`, `state`, `summary`, `assumptions`, `checks`, `review`, `finalVerification`, `headSha`, `updatedAt`, `nextAction`.
- `review` should include at least: `status`, `scope`, `completedAt`, `summary`.
- `finalVerification` should include at least: `status`, `commands`, `completedAt`.
- Preferred state progression:
  - `booting`
  - `implementing`
  - `checking`
  - `reviewing`
  - `fixing-review`
  - `final-check`
  - `done` or `blocked`

Required workflow:

1. Restate the subtask tersely in your own words.
2. Identify the smallest correct implementation plan.
3. Implement the change completely.
4. Run the focused verification commands for the subtask.
5. Run the review workflow against your current changes.
   - Prefer the repo's `/review` extension when available.
   - If that is not directly invokable from the current worker run, use an equivalent host-side or nested pi review pass against the current worktree and consume the full review output.
6. Fix the review findings that matter.
7. Rerun verification.
8. Create a small, reviewable commit for the finished change in the worker worktree.
9. Record the resulting `HEAD` commit SHA as `headSha` in `.hive/status.json`, along with a done-ready summary.
10. Leave a terse final report with:
   - what changed
   - files touched
   - checks run
   - review issues addressed
   - any residual risks or follow-up ideas

Blocked-state rules:

- Only stop early for a real blocker.
- If blocked, write the blocker clearly into `.hive/status.json` with the smallest concrete unblock request.
- Do not claim `done` without leaving a clean, committed `headSha` for the orchestrator to integrate.
- Do not leave the worktree in an ambiguous half-done state without recording what remains.

The orchestrator will merge and verify your work later, so optimize for a clean, reviewable, low-surprise result.
