# Runtime roadmap

This extension started with prompts and skill docs first, but the core runtime now exists.
The phases below reflect the implemented behavior and the main remaining gaps.

## Phase 0: workflow contract

Implemented:

- define the orchestrator template
- define the worker template
- define the worker/orchestrator operating contract
- define the polling/merge model

## Phase 1: host-side worker launcher

Implemented via the `hive_worker` tool:

1. read the worker template from this package
2. ensure the worker exists via `hive up`
3. write worker-local launcher/status files into that worker's `.hive/` directory inside the hive-managed worktree
4. launch a detached worker through `hive exec`
5. run `pi --mode json -p --no-session` in the worker worktree
6. store machine-readable logs for polling

This follows pi's `subagent` example closely, but replaces direct local `pi` subprocesses with hive-managed worktrees.

## Phase 2: repo-local orchestration state + loop control

Implemented via the `hive_orchestrator` tool and host commands:

- creating repo-local orchestrator files under `.hive/orchestrator/`
- keeping `.hive/orchestrator/plan.md` in sync with queue state
- persisting `.hive/orchestrator/queue.json` and appending incremental progress entries to `.hive/orchestrator/progress.md`
- polling running workers through queue state and worker snapshots
- parsing JSON logs into recent event summaries
- `/hive-status` and `/hive-tick` for one-shot inspection and advancement
- `/hive-loop` for repeated ticking
- `/hive-stop` for loop stop requests
- foreground loop start from `/hive-run` when the planning turn leaves a live queue, with the command staying attached until the queue drains or needs attention

Files under `.hive/orchestrator/` are repo-local orchestrator artifacts.
They are separate from the worker-local `.hive/*` launch/status files stored inside each hive-managed worker worktree.

`.hive/orchestrator/planning-notes.md` is optional planning output written by the `/hive-run` planning workflow.
It is not part of the orchestrator runtime state machine and is not maintained by `poll`, `tick`, or `/hive-loop`.

## Phase 3: merge queue automation

Implemented in the current runtime:

- create a persistent clean coordinator integration worktree for each queue
- cherry-pick verified worker commits onto the coordinator integration branch
- run repo-level final checks there
- accept legacy worker completion statuses like `completed` during done-state validation
- apply deterministic fixups for check/lint failures when they can be derived safely from the failing command
- mark tasks merged when integration succeeds
- keep retryable/replaced blocked tasks from unnecessarily stopping the foreground loop
- auto-create follow-up tasks for integration conflicts or non-deterministic final-check failures

Still to add:

- an explicit final landing flow from the coordinator worktree onto a user branch
- smarter conflict-resolution flows beyond cherry-pick abort/reset plus follow-up task creation
- richer policy for when the host should fix forward directly vs dispatch another worker
- an optional detached/background `/hive-run` mode layered on top of the same queue/loop runtime

## Phase 4: review-cycle automation

Partially implemented today through the worker contract and done-status validation:

1. implement the task
2. run review on the worker's own delta
3. fix meaningful findings
4. rerun checks before marking `done`

Still to add:

- a dedicated host/runtime-enforced review pass rather than relying primarily on worker self-management
- stronger review/fixup enforcement signals before integration
