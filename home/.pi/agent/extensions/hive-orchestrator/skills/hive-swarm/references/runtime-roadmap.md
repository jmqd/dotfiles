# Runtime roadmap

This extension scaffold intentionally starts with prompts + skill docs first.

## Phase 0: workflow contract

Done in this commit:

- define the orchestrator template
- define the worker template
- define the worker/orchestrator operating contract
- define the polling/merge model

## Phase 1: host-side worker launcher

Build a real extension command/tool that:

1. reads the worker template from this package
2. writes a temp system-prompt file
3. launches a worker via `hive exec` or `hive up --cmd`
4. runs `pi --mode json -p --no-session` in the worker worktree
5. stores machine-readable logs for polling

This should follow pi's `subagent` example closely, but replace direct local `pi` subprocesses with hive-managed worktrees.

## Phase 2: orchestration state + poller

Add host-side commands/tools for:

- creating the orchestrator queue files
- polling worker status
- parsing JSON logs
- tracking worker lifecycle
- emitting incremental progress messages

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
