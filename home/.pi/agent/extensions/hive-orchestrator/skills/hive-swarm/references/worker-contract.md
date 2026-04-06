# Worker contract

## Goal

Each hive worker should take one clean subtask from assignment to done-ready handoff with no interactive back-and-forth.

## Worker responsibilities

A worker must:

1. own one subtask only
2. implement the required change fully
3. run focused verification
4. run review on its own delta
5. fix review findings
6. rerun verification
7. emit structured status

A worker must not:

- self-merge into main
- quietly expand scope
- stop after coding but before review/checks
- leave ambiguous progress without a status update

## Suggested status schema

Use `.hive/status.json` in the worker worktree.

Example:

```json
{
  "task": "add retry handling to foo client",
  "state": "reviewing",
  "summary": "Implementation complete; running review pass",
  "assumptions": [
    "existing retry budget is the intended policy surface"
  ],
  "checks": [
    "cargo test -p foo-client",
    "cargo test retry::tests"
  ],
  "review": {
    "status": "running",
    "command": "pi -p /review uncommitted"
  },
  "headSha": "abc123",
  "updatedAt": "2026-04-06T00:00:00Z",
  "nextAction": "address review findings"
}
```

## State meanings

- `booting`: worker started, reading the task
- `implementing`: making code changes
- `checking`: running task-local checks
- `reviewing`: running review against the worker delta
- `fixing-review`: applying review-driven fixes
- `final-check`: rerunning verification after review fixes
- `done`: ready for orchestrator integration
- `blocked`: cannot proceed without a concrete unblock

## Review expectation

The required quality bar is:

1. review the worker delta
2. address meaningful findings
3. rerun checks
4. only then mark `done`

If the runtime environment cannot directly invoke `/review` from inside the worker run, use a host-side nested pi review pass against the worker worktree and feed the results back into the worker fixup phase.

## Final handoff

A done-ready worker should leave:

- a final `headSha`
- concise summary of what changed
- list of checks run
- brief note on review findings addressed
- any residual risks worth the orchestrator knowing before merge
