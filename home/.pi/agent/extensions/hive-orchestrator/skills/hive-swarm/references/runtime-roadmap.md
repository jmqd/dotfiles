# Runtime roadmap

This extension scaffold intentionally starts with prompts + skill docs first.

## Phase 0: workflow contract

Done in this commit:

- define the orchestrator template
- define the worker template
- define the worker/orchestrator operating contract
- define the polling/merge model

## Phase 1: host-side worker launcher

Implemented in this commit via the `hive_worker` tool:

1. read the worker template from this package
2. write launcher files into the worker worktree under `.hive/`
3. ensure the worker exists via `hive up`
4. launch a detached worker through `hive exec`
5. run `pi --mode json -p --no-session` in the worker worktree
6. store machine-readable logs for polling

This follows pi's `subagent` example closely, but replaces direct local `pi` subprocesses with hive-managed worktrees.

## Phase 2: orchestration state + poller

Implemented in this commit via the `hive_orchestrator` tool and host commands:

- creating the orchestrator queue files
- keeping `.hive/orchestrator/plan.md` in sync with the queue
- polling running workers through queue state
- parsing JSON logs into recent event summaries
- tracking worker lifecycle files in `.hive/`
- appending incremental orchestrator progress messages
- host-side loop helpers via `/hive-loop` and `/hive-stop`
- automatic loop start from `/hive-run` when the planning turn leaves a live queue

Still to add:

- smarter conflict-resolution flows beyond basic cherry-pick failure handling
- stronger review/fixup enforcement signals before integration

## Phase 3: merge queue automation

Add host-side helpers for:

- integrating worker work into the host main worktree
- resolving simple conflicts
- rerunning `just check`
- marking tasks merged vs needing follow-up

## Phase 4: review-cycle automation

Make worker completion reliably include:

1. implementation pass
2. automated review pass against the worker worktree
3. automated fixup pass
4. final worker done marker

That can be implemented either inside one worker flow or as separate host-orchestrated pi invocations against the same worker worktree.
