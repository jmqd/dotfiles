# hive-orchestrator

Pi extension scaffold for long-running `hive`-backed parallel work.

## What this commit adds

- `/hive-orchestrator` prompt template for the top-level orchestrator worker
- `/hive-worker` prompt template for a non-interactive hive worker
- `hive-swarm` skill with the core operating contract and reference docs
- a small extension entrypoint that exposes those resources via `resources_discover`

## Why this shape

The current goal is to lock down the workflow contract before building runtime automation.
The prompt templates and skill define the behavior we want from:

- the orchestrator: split work, dispatch workers, poll progress, merge finished work, resolve conflicts, and run final checks
- the workers: take one clean subtask to completion, run review on their own changes, fix issues, and report a structured done state

## Important implementation note

A future automation layer should follow pi's `subagent` example pattern:

- generate worker system prompts from these templates
- launch worker `pi` runs in `hive` worktrees via `hive exec` or `hive up --cmd`
- prefer `pi --mode json -p --no-session` for machine-readable logs
- keep the orchestrator on the host side so it can merge into the main worktree and run final checks

That matters because hive containers do not automatically inherit host-global `~/.pi/agent` resources.
The reliable path is to have the host extension inject the worker prompt/template into each worker invocation.

## Resource layout

- `prompts/hive-orchestrator.md`
- `prompts/hive-worker.md`
- `skills/hive-swarm/SKILL.md`

See `plans/pi-hive-orchestrator-extension.md` for the fuller build plan.
