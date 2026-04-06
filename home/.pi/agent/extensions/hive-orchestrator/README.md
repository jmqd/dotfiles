# hive-orchestrator

Pi extension for long-running `hive`-backed parallel work.

## What exists now

- `/hive-orchestrator` prompt template for the top-level orchestrator worker
- `/hive-worker` prompt template for a non-interactive hive worker
- `hive-swarm` skill with the core operating contract and reference docs
- a `hive_worker` tool that can:
  - launch one worker in a hive worktree
  - write `.hive/status.json`
  - capture the worker's pi JSON event stream to `.hive/worker-events.jsonl`
  - poll the worker's status/log snapshot later
- a `hive_orchestrator` tool that can:
  - initialize `.hive/orchestrator/plan.md`, `queue.json`, and `progress.md`
  - enqueue clean worker subtasks
  - poll running workers through the queue
  - verify done workers in a temporary integration worktree
  - cherry-pick verified worker commits onto the host integration branch
  - tick the queue forward by polling, integrating, and dispatching dependency-ready tasks
- user-facing commands:
  - `/hive-run <goal>`
  - `/hive-init <goal>`
  - `/hive-status`
  - `/hive-tick`
  - `/hive-loop [seconds]`
- an extension entrypoint that exposes the resources and registers the tools/commands

## Why this shape

The current goal is to lock down the workflow contract before building runtime automation.
The prompt templates and skill define the behavior we want from:

- the orchestrator: split work, dispatch workers, poll progress, merge finished work, resolve conflicts, and run final checks
- the workers: take one clean subtask to completion, run review on their own changes, fix issues, and report a structured done state

## Runtime shape

The launcher follows pi's `subagent` example pattern:

- generate a worker system prompt from the worker template
- launch a detached worker `pi` run in a hive worktree
- use `pi --mode json -p --no-session` for machine-readable logs
- keep the orchestrator on the host side so it can merge into the main worktree and run final checks

That matters because hive containers do not automatically inherit host-global `~/.pi/agent` resources.
The reliable path is to have the host extension inject the worker prompt/template into each worker invocation.

## Current orchestrator artifacts

The orchestrator keeps these host-worktree files (normally ignored by git via `.gitignore`):

- `.hive/orchestrator/plan.md`
- `.hive/orchestrator/queue.json`
- `.hive/orchestrator/progress.md`

## Invoking it from pi

High level:

- use `/hive-run <goal>` when you want pi to inspect the repo, make a solid plan, choose concurrency, write planning notes, initialize/resume the queue, enqueue tasks, and start the workflow
- use `/hive-orchestrator <goal>` when you want the model to drive the workflow more manually from the prompt template
- use `/hive-init <goal>` to initialize queue state directly without the higher-level planning workflow
- use `/hive-status` to poll and display queue state
- use `/hive-tick` to run one poll/integrate/dispatch step
- use `/hive-loop 30` to keep ticking every 30 seconds until the queue drains or needs attention

`/hive-run` uses a dedicated one-turn workflow system prompt that forces:

- a real planning phase before worker launch
- an explicit concurrency decision
- planning notes in `.hive/orchestrator/planning-notes.md`
- queue initialization/resume + first tick

You can also explicitly tell the model:

- "Use the `hive_orchestrator` tool to init, enqueue tasks, and keep calling tick"
- "Use the `hive_worker` tool only for low-level worker inspection or one-off launches"

## Current worker artifacts

Each launched worker worktree gets:

- `.hive/status.json`
- `.hive/worker-launch.json`
- `.hive/worker-system-prompt.md`
- `.hive/worker-events.jsonl`
- `.hive/worker-stderr.log`
- `.hive/worker.pid`
- `.hive/worker-exit-code`

## Resource layout

- `prompts/hive-orchestrator.md`
- `prompts/hive-worker.md`
- `skills/hive-swarm/SKILL.md`

See `plans/pi-hive-orchestrator-extension.md` for the fuller build plan.
