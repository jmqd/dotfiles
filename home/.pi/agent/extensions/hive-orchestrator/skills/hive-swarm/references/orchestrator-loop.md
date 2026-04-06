# Orchestrator loop

## Goal

The orchestrator is the long-lived control plane. It is responsible for:

- task decomposition
- worker assignment
- merge queue management
- conflict resolution
- final verification
- progress reporting

## Core loop

Prefer a bounded polling loop instead of one-shot fire-and-forget orchestration.

```text
while any task is unmerged and not terminally blocked:
  refresh the queue state
  poll each worker's status artifact and logs
  report meaningful state changes

  for each worker that is done-ready and not yet integrated:
    merge into the host main worktree
    resolve conflicts
    run final checks
    if checks fail:
      fix directly or dispatch a follow-up worker
    else:
      mark merged

  for blocked workers:
    either unblock directly or split out a new follow-up task

  sleep for a bounded interval
```

## Merge queue rules

- Merge incrementally as workers finish.
- Prefer the lowest-conflict order, not just the earliest-finished order.
- Keep the host worktree as the source of truth for integration state.
- After each merge, re-evaluate remaining workers for conflict risk.

## Conflict policy

If a worker conflicts with current main:

1. try to resolve in the host worktree directly if the conflict is small
2. rerun checks
3. if the fix is no longer small, create a new follow-up worker task with the merged context

## Final verification

Use a repo-specific final command set. If no better default exists, use `just check`.

Typical order:

1. targeted checks related to the merged task
2. broader repository check (`just check`)
3. optional smoke tests if they are fast enough

## Progress reporting

Report at least when:

- initial task graph is ready
- a worker starts
- a worker becomes blocked
- a worker finishes implementation
- a worker finishes review/fixup
- a worker is merged
- final checks fail
- all work is integrated

Keep updates terse and cumulative.
