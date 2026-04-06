---
name: hive-swarm
description: Orchestrate long-running parallel coding work with hive workers and a top-level orchestrator. Use when a task can be split into independent subtasks, workers must run non-interactively to completion, and the orchestrator must merge, verify, and track progress over time.
---

# Hive Swarm

Use this skill when the work is big enough to justify parallel execution through `hive`, but still needs one coordinating orchestrator that owns integration quality.

## Core model

- One **orchestrator** owns the host worktree, task graph, merge queue, conflict resolution, and final checks.
- Many **workers** run in isolated hive worktrees and each own one crisp subtask.
- Workers do not ask interactive questions unless they are truly blocked.
- Workers do not merge themselves.
- Finished worker output is not considered complete until the orchestrator merges it and final checks pass.

Read these references before running the workflow:

- [Worker contract](references/worker-contract.md)
- [Orchestrator loop](references/orchestrator-loop.md)
- [Runtime roadmap](references/runtime-roadmap.md)

## Non-negotiable rules

1. Split work into clean subtasks with minimal overlap.
2. Give every worker a precise done condition and verification command set.
3. Require every worker to review its own changes and address the review.
4. Merge completed work incrementally; do not hold everything until the end.
5. Run final checks from the orchestrator's host worktree before considering a task integrated.
6. Record status in machine-readable form so the orchestrator can poll for hours if needed.

## Minimum artifacts

In the host worktree:

- `.hive/orchestrator/plan.md`
- `.hive/orchestrator/queue.json`
- `.hive/orchestrator/progress.md`

In each worker worktree:

- `.hive/status.json`
- optional `.hive/final-report.md`

## Dispatch pattern

Use the `hive_orchestrator` tool as the default host-side control plane, and the `hive_worker` tool as the lower-level worker launcher/poller.
Under the hood the worker path follows this pattern:

1. turns the worker template into a worker system prompt
2. launches `pi --mode json -p --no-session` inside the worker worktree
3. captures JSON logs for incremental progress
4. polls the worker status artifact until the worker is done or blocked

## Integration bar

A worker is only truly complete when all of these are true:

- implementation finished
- focused checks passed in the worker worktree
- review run completed and findings addressed
- orchestrator merged the work onto main
- orchestrator final checks passed

## When not to use this skill

Do not use hive orchestration when:

- the task is too small for parallelism
- the subtasks heavily overlap in the same files
- the repo has no fast verification path
- the integration order is too unclear to define safe task boundaries
