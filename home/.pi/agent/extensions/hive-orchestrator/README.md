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
  - `/hive-stop`
- an extension entrypoint that exposes the resources and registers the tools/commands

## Why this shape

The workflow contract still drives the design, but the extension now also ships the core host-side runtime.
The prompt templates and skill define the expected behavior, while the tools and commands implement the current launcher, queue, loop, and integration path:

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

## Repo-local orchestrator files

The host orchestrator stores repo-local state under `.hive/orchestrator/` (normally ignored by git via `.gitignore`).
These repo-local files are distinct from the per-worker `.hive/*` artifacts stored inside each hive-managed worker worktree.

Runtime-maintained orchestrator state:

- `.hive/orchestrator/plan.md`
- `.hive/orchestrator/queue.json`
- `.hive/orchestrator/progress.md`

Planning workflow output:

- `.hive/orchestrator/planning-notes.md` — written by `/hive-run` during the planning turn.
  Useful for context, but not part of runtime queue state.
  `hive_orchestrator poll`, `hive_orchestrator tick`, and `/hive-loop` do not maintain it.

## Invoking it from pi

High level:

- use `/hive-run <goal>` when you want pi to inspect the repo, make a solid plan, choose concurrency, write planning notes, initialize/resume the queue, enqueue tasks, and then auto-start the host-side loop when a live queue exists
- use `/hive-orchestrator <goal>` when you want the model to drive the workflow more manually from the prompt template
- use `/hive-init <goal>` to initialize queue state directly without the higher-level planning workflow
- use `/hive-status` to poll and display queue state
- use `/hive-tick` to run one poll/integrate/dispatch step
- use `/hive-loop 30` to keep ticking every 30 seconds until the queue drains or needs attention
  - omit the argument to use the queue's persisted `pollIntervalSeconds`
- use `/hive-stop` to request stop for a running loop without waiting for the full sleep interval

`/hive-run` uses a dedicated one-turn workflow system prompt that forces:

- a real planning phase before worker launch
- an explicit concurrency decision
- planning notes in `.hive/orchestrator/planning-notes.md` as planning output, separate from the runtime queue files
- queue initialization/resume + first tick

After that planning turn finishes, the extension automatically starts `/hive-loop` in the same pi session when the queue is live and non-terminal. The loop keeps polling/integrating/dispatching until the queue drains, blocks, fails, or you stop it with `/hive-stop`.

The extension also keeps a small live queue widget in the UI when a queue is present.

You can also explicitly tell the model:

- "Use the `hive_orchestrator` tool to init, enqueue tasks, and keep calling tick"
- "Use the `hive_worker` tool only for low-level worker inspection or one-off launches"

## Worker-local artifacts

Each launched worker worktree gets its own `.hive/*` files. These live inside the hive-managed worker worktree for that agent, not under the repo-local `.hive/orchestrator/` directory:

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

Note: the auto-loop is session-local. If pi exits or reloads, restart it with `/hive-loop`.
