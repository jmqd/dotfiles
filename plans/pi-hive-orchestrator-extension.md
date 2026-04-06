# pi hive orchestrator extension plan

## Status

Planning + prompt/skill scaffolding + runnable worker launcher + orchestrator queue manager + automated integration/check path.

## Objective

Build a pi extension that uses `hive` to coordinate long-running parallel worker runs, where:

- the **orchestrator** is the top-level controller
- **workers** each take one clean subtask to completion without interactive questions
- each worker runs a full review pass and addresses issues before claiming done
- the orchestrator polls progress, merges finished work incrementally, resolves conflicts, and runs final checks before integration

## Constraints discovered up front

1. The current `hive` tool provides the right lifecycle primitives: `up`, `ls`, `exec`, `logs`, `attach`, and `down`.
2. Pi prompt templates and skills are good for encoding the workflow contract, but they are not enough by themselves to launch robust long-running workers.
3. Pi's `subagent` example shows the right host-side automation pattern:
   - generate system prompts from templates
   - launch `pi --mode json -p --no-session`
   - capture structured output for progress tracking
4. Hive containers do not automatically inherit host-global `~/.pi/agent` resources, so the runtime extension should inject worker prompts from the host side rather than assuming in-container discovery.
5. For this repo, the most reliable worker invocation path is `nix develop -c pi --mode json -p --no-session` inside the worker worktree.

## Proposed architecture

### 1. Resource package inside a pi extension

Keep the workflow contract in one place:

- orchestrator prompt template
- worker prompt template
- `hive-swarm` skill
- reference docs for worker and orchestrator behavior

This commit implements that scaffold under `home/.pi/agent/extensions/hive-orchestrator/`.

### 2. Host-side orchestrator runtime

The real automation should live on the host side, not inside each worker container.

Responsibilities:

- split the top-level goal into clean subtasks
- assign those subtasks to worker slots
- launch and monitor worker runs through `hive`
- parse worker status + logs
- merge finished work into the host main worktree
- resolve conflicts
- run final checks
- emit incremental progress updates for hours if needed

### 3. Worker execution model

Recommended pattern per worker:

1. create or reuse a hive worker worktree
2. inject the worker template as a system prompt
3. launch a non-interactive pi run in the worker worktree:

```text
pi --mode json -p --no-session --append-system-prompt <worker-prompt> "Task: ..."
```

4. capture JSON logs for progress polling
5. require the worker to maintain `.hive/status.json`
6. when implementation is done, run a review pass and a fixup pass before marking the worker `done`

## Review-cycle plan

The desired behavior is:

1. worker completes the coding task
2. worker runs `/review` on its delta
3. worker addresses the review findings
4. worker reruns checks
5. worker marks itself done-ready

The most reliable implementation path is probably host-driven multi-step automation against the same worker worktree:

- implementation run
- review run
- fixup run
- final check run

That avoids depending on a single worker session to recursively drive its own slash commands.

## Merge queue plan

The orchestrator should merge finished work incrementally instead of waiting for every worker to finish.

Suggested policy:

- keep a queue file under `.hive/orchestrator/`
- poll workers in a bounded sleep/check loop
- whenever a worker is done-ready:
  - inspect its status + latest commits
  - integrate onto the host main worktree
  - resolve conflicts there
  - run `just check`
  - mark the task merged only after checks pass
- if integration fails badly, create a new clean follow-up worker task

## State model

### Host worktree

- `.hive/orchestrator/plan.md`
- `.hive/orchestrator/queue.json`
- `.hive/orchestrator/progress.md`

### Worker worktree

- `.hive/status.json`
- optional `.hive/final-report.md`

## Milestones

### Milestone 1

Done in this commit:

- add the `hive-orchestrator` extension scaffold
- add `/hive-orchestrator`
- add `/hive-worker`
- add the `hive-swarm` skill and reference docs

### Milestone 2

Implemented in this commit via the `hive_worker` tool:

- dispatch one worker through `hive`
- inject the worker prompt into the worker worktree
- capture JSON logs
- write `.hive/status.json`
- poll a worker snapshot later

### Milestone 3

Implemented in this commit via the `hive_orchestrator` tool:

- initialize `.hive/orchestrator/plan.md`
- initialize `.hive/orchestrator/queue.json`
- initialize `.hive/orchestrator/progress.md`
- enqueue tasks
- poll running workers
- verify done workers in a temporary integration worktree
- cherry-pick verified worker commits onto the host branch
- dispatch dependency-ready planned tasks during `tick`

### Milestone 4

Add automated review/fixup sequencing for each worker.

### Milestone 5

Add ergonomic progress rendering in pi via custom messages or a small status widget.

## Immediate next step

Add more robust conflict-handling and autonomous looping on top of `hive_orchestrator`:

- teach the orchestrator to create follow-up worker tasks automatically after blocked integrations
- add optional bounded sleep/re-tick helper flows for long unattended runs
- improve merge conflict recovery beyond simple cherry-pick blocking
