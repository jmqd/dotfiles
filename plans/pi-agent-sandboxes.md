# Agent Fleet Sandboxes Plan

## Goal
Spin up `N` isolated coding agents for the same repo, with:
- a separate working tree per agent
- container-level isolation (filesystem, process, network)
- the repo's dev environment pre-activated so tools work without manual setup
- permission-gating friction removed because the container boundary is the real safety mechanism
- both headless orchestration and optional human interaction with an individual agent
- agent-agnostic design: the fleet tool manages sandboxes, not any specific agent

## Target Agent Runtimes
The fleet tool is agent-agnostic. Initial use cases:
- **Claude Code** (`claude --dangerously-skip-permissions`)
- **pi** (`pi --mode rpc --no-session`)
- **Codex** (`codex --full-auto`)

The agent command is a configurable parameter. The fleet tool's job is container lifecycle and environment provisioning — the agent is just a process that runs inside it.

## Design Priorities
1. **Isolation first**: agents should not touch the host repo checkout.
2. **Fast spin-up**: avoid rebuilding the same dev environment per agent.
3. **Cheap parallelism**: N agents should share immutable artifacts where safe.
4. **Good ergonomics**: starting a fleet should be one command.
5. **Debuggability**: it should be easy to attach to one agent/container when something goes wrong.
6. **Cross-platform**: must work on macOS (primary) and Linux.

## Recommended Architecture

### 1. Container runtime: Docker / OrbStack
Use Docker containers as the isolation primitive.

On macOS: OrbStack provides fast, lightweight Docker with near-native performance on Apple Silicon. The Linux VM it manages already has access to `/nix/store`.

On Linux: standard Docker or Podman.

Why Docker over `systemd-nspawn`:
- works on both macOS and Linux (nspawn is Linux-only)
- OrbStack makes it fast on macOS
- well-understood tooling, easy to attach/debug
- bind mounts, volume mounts, networking all work cleanly
- `docker exec -it` for shell access

### 2. Repo source model: per-agent git worktrees
For MVP, create worktrees directly from the live repo:

```bash
git worktree add /tmp/fleet/agent-01 HEAD --detach
git worktree add /tmp/fleet/agent-02 HEAD --detach
```

Each agent gets its own worktree bind-mounted writable into its container.

Why start simple:
- `git worktree add` is fast and cheap
- cleanup is `git worktree remove`
- avoids the complexity of maintaining a bare mirror

Future option — bare mirror for scale:
- if N concurrent agents cause `.git/worktrees` contention, move to a bare mirror
- `~/.local/share/agent-fleet/repos/<project>.git` with per-agent worktrees from that mirror
- only build this if the simple approach breaks

### 3. Nix dev environment: host store, shared read-only
For MVP, mount the **host Nix store read-only** into containers.

On macOS with OrbStack/Docker, the Nix store is already available in the Linux VM. Mount it into each container:

```bash
docker run -v /nix/store:/nix/store:ro ...
```

Agents activate the dev environment via:
```bash
nix develop <repo> -c <agent-command>
```

Why skip a dedicated fleet store for now:
- the host store already has everything built
- avoids the complexity of a separate daemon, socket, and volume
- only revisit if host store contamination becomes a real problem

Future option — dedicated fleet store:
- one long-lived store daemon container
- its `/nix` on a dedicated volume
- agent containers mount that store read-only
- useful if you want full host isolation or run on remote machines

## Interaction Model

### Layer 1: fleet tool (agent-agnostic)
The fleet tool manages container lifecycle only:
- start/stop containers
- provision worktrees
- activate dev environments
- attach shell to any container
- stream logs
- cleanup

### Layer 2: agent drivers (optional, per-agent)
Thin adapters for orchestration beyond "give me a shell":

| Agent | Send prompt | Get status | Stream output |
|-------|-------------|------------|---------------|
| Claude Code | `claude -p "..."` or Agent SDK | session files | stdout/stderr |
| pi | RPC protocol | RPC status | RPC event stream |
| Codex | stdin | exit code | stdout/stderr |

Layer 2 is **not needed for MVP**. Start with `fleet attach` for interactive use and `fleet exec` for scripted use.

### Interactive attach
```bash
fleet attach agent-01          # shell inside the container
fleet attach agent-01 --agent  # launch the agent TUI interactively
fleet logs agent-01            # tail container logs
```

## Permission Model
The container boundary is the safety mechanism.

- Agents run with full permissions inside their container
- The container cannot touch the host filesystem beyond its bind-mounted worktree
- No need for agent-level permission gating (Claude's `--dangerously-skip-permissions`, pi's trusted sandbox, codex's `--full-auto`)
- The host repo checkout is never modified by agents

Per-agent flags for permissive mode:
- Claude Code: `--dangerously-skip-permissions`
- pi: `--no-session` + no permission-gating extensions
- Codex: `--full-auto`

## Proposed CLI Shape

```bash
fleet up --repo ~/src/project --agents 3
fleet up --repo ~/src/project --agents 3 --cmd "claude --dangerously-skip-permissions"
fleet up --repo ~/src/project --agents 3 --cmd "pi --mode rpc --no-session"

fleet ls                                    # list running agents
fleet attach agent-01                       # shell into container
fleet exec agent-01 "run the test suite"    # run a command in the agent's shell
fleet logs agent-01                         # tail logs
fleet down                                  # stop all, clean up worktrees
fleet down --keep-worktrees                 # stop containers, keep worktrees
```

### `fleet up` internals
1. Create N git worktrees from the repo
2. Build/ensure the Nix dev environment closure
3. Launch N Docker containers, each with:
   - its worktree bind-mounted writable
   - host `/nix/store` mounted read-only
   - isolated `$HOME`, tmp, cache dirs
   - `nix develop` as the entrypoint wrapper
4. If `--cmd` is provided, run the agent command inside `nix develop`
5. Otherwise, containers idle with a shell, ready for `fleet attach`

### `fleet down` internals
1. Stop and remove containers
2. Remove git worktrees (unless `--keep-worktrees`)
3. Clean up state/logs

## Storage / State Layout
```text
~/.local/share/agent-fleet/
├── worktrees/
│   └── <project>/
│       ├── agent-01/
│       ├── agent-02/
│       └── ...
├── logs/
│   ├── agent-01.log
│   └── ...
└── runtime/
    └── metadata/
```

## Container Image Strategy
Use a minimal base image with Nix pre-installed:
- `nixos/nix` or a custom image with Determinate Nix
- The image is built once and cached; dev environment activation happens at container start via `nix develop`
- Consider pre-baking the dev environment closure into the image for faster spin-up at scale

## MVP Plan

### MVP v1: one agent, one command
- `fleet up --repo <path>` starts one container
- one git worktree from the live repo
- host Nix store mounted read-only
- `nix develop` activates the dev env
- `fleet attach` gives a shell
- `fleet down` cleans up
- implemented as a small bash script

### MVP v2: N agents
- `--agents N` flag
- parallel container launch
- `fleet ls` to list agents
- `fleet attach agent-N` to pick one
- `fleet logs agent-N`

### MVP v3: orchestration
- `--cmd` to auto-launch an agent in each container
- `fleet exec` to send commands to running agents
- basic log aggregation
- optional: Layer 2 agent drivers for prompt/status/stream

### MVP v4: scale and polish
- broadcast commands to all agents
- result aggregation / diffing across agents
- bare mirror for repos with many concurrent agents
- optional dedicated fleet Nix store
- optional specialized agent roles/prompts

## Key Tradeoffs

### Docker vs `systemd-nspawn`
**Docker first.**

Pros:
- cross-platform (macOS + Linux)
- OrbStack makes it fast on Apple Silicon
- familiar tooling
- easy attach/debug

Cons:
- slightly heavier than nspawn on Linux
- Docker daemon dependency

If Linux-only deployment becomes important, nspawn can be added as an alternative backend without changing the CLI interface.

### Host store vs dedicated fleet store
**Host store for MVP.**

The host already has the closures built. Mounting read-only is free. Only build a dedicated store if:
- host store contamination is a real problem
- you want agents to install packages without affecting the host
- you're running fleet on remote machines without a pre-populated store

### Worktrees from live repo vs bare mirror
**Live repo worktrees for MVP.**

`git worktree add` is fast and simple. Only move to a bare mirror if:
- `.git/worktrees` contention becomes a problem with N agents
- you need worktrees on a different branch/ref than what's checked out
- fleet runs against remote repos

## Resolved Questions
- **Agent rootfs**: ephemeral per run, with a cached Docker image for the base layer.
- **Worktrees**: recreated per run (clean slate). Cheap with git.
- **Controller**: shell script first. Migrate to Agent SDK or typed program when real orchestration is needed.
- **Attach**: both shell (`docker exec`) and agent TUI (run agent interactively inside the container).
- **Specialized roles**: generic workers only for MVP. Roles/prompts are a Layer 2 concern.

## Follow-up Implementation Targets
Potential repo additions:
- `bin/fleet` — the main CLI script
- `pkgs/fleet-image/` — Nix expression for the base Docker image
- `plans/pi-agent-sandboxes.md` — this plan
- optional: Layer 2 agent driver scripts per agent runtime
