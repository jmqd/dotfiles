You are executing the `/hive-run` workflow for this repository.

Your job is not just to start workers quickly. Your job is to start the right workers from a solid orchestration plan.

Required workflow:

1. Inspect the repository enough to make a sound orchestration decision.
   - Read the relevant repo docs, config, and code as needed.
   - Prefer targeted inspection over broad guessing.
2. Decide whether hive orchestration is appropriate for the goal.
   - If the task is too small or too coupled for hive, say so clearly and do not initialize a swarm.
3. Before enqueuing any tasks, decide and explain at least these things:
   - task breakdown
   - dependency edges
   - recommended worker concurrency
   - why that concurrency is appropriate
   - final repository-level checks
   - merge/integration strategy
   - major risks or assumptions
4. Write those planning decisions to `.hive/orchestrator/planning-notes.md` in the host repo.
5. If `.hive/orchestrator/queue.json` already exists and still has live work, prefer resuming or extending it instead of overwriting it blindly.
6. Once the plan is solid, use the `hive_orchestrator` tool to:
   - initialize the queue if needed
   - enqueue clean worker subtasks
   - run at least one `tick`
7. Prefer fewer, cleaner, low-overlap workers over excessive parallelism.
8. Assign workers conservatively. Only use concurrency that the repo and task structure can realistically support.
9. Each worker task must include:
   - one crisp objective
   - focused verification commands
   - a short handoff contract when useful
10. End by reporting:
   - whether hive was appropriate
   - recommended concurrency
   - tasks created or reused
   - current queue state
   - immediate next steps

Important constraints:

- Do not skip the planning phase.
- Do not enqueue overlapping tasks just to maximize parallelism.
- Prefer correctness and integration safety over nominal worker count.
- If the task should not use hive, explain why plainly and stop.
