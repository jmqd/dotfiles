# Hive Phone Access Plan

## Decision
Use a small always-on VPS as the remote control point for coding agents, with:
- `hive` managing per-agent containers/worktrees
- `tmux` as the primary operator UI
- `ssh` over Tailscale as the default transport
- `mosh` as an optional upgrade for mobile clients that support it

This is the chosen first implementation because it works for all target agents (`pi`, Claude Code, Codex) without needing vendor-specific cloud features or a custom mobile UI.

See also: [plans/pi-agent-sandboxes.md](./pi-agent-sandboxes.md) for the broader sandbox/runtime design.

## Goals
1. Reach running agents from a phone with minimal latency and minimal new infrastructure.
2. Reuse the existing `hive` model instead of building a new orchestration layer.
3. Keep the system private-by-default.
4. Support all current agent runtimes, not just `pi`.
5. Preserve a path to nicer future UX (notifications, control API, pi RPC UI) without blocking on it now.

## Non-Goals
- Do not build a custom mobile app yet.
- Do not expose a public web terminal or public HTTP control plane for MVP.
- Do not depend on vendor-managed hosted agent features.
- Do not redesign `hive` around a remote-only architecture before proving the workflow is useful.

## Chosen Architecture

```text
phone
  └── ssh (over Tailscale)
        └── VPS
              ├── tmux session(s)
              ├── hive
              │    ├── per-agent git worktrees
              │    └── per-agent Docker containers
              ├── agent runtimes
              │    ├── pi
              │    ├── claude
              │    └── codex
              └── repo checkout(s)
```

### Why this architecture
- Lowest implementation risk.
- Uses tools that already exist in this repo (`hive`).
- `tmux` gives persistence, multiplexing, and resilience to disconnects.
- Tailscale avoids exposing SSH publicly and removes most networking pain.
- If the connection drops, the agents keep running and the `tmux` session survives.

## Recommended Transport Model

### Baseline
- **Tailscale** between phone and VPS
- **SSH** into the VPS
- **tmux** for persistent sessions

### Optional upgrade
- **mosh** on top of the same VPS for mobile clients that support it
- keep `tmux` even with `mosh`; `mosh` solves network instability, `tmux` solves session persistence

### Why not web first
A web terminal is still a valid fallback later, but SSH/Tailscale is simpler, safer, and better aligned with a terminal-native workflow.

## VPS Shape

### MVP recommendation
Use a small Linux VPS with:
- Docker
- Nix
- Tailscale
- tmux
- mosh (optional)
- git

### Distro choice
Prefer the smallest thing that gets you to a working shell quickly:
- acceptable MVP: Ubuntu or Debian + Nix + Docker + Tailscale
- later improvement: migrate to a declaratively managed NixOS VPS if it proves useful

Rationale:
- time-to-value matters more than ideological purity for the first iteration
- the value is in the remote workflow, not in perfect host management on day one

## Repo / Runtime Model on the VPS

### Source of truth
- Keep one normal repo checkout per project on the VPS.
- Use `hive` to create per-agent worktrees from that checkout.

### Agent execution
Use the same `hive` commands already envisioned locally.

Examples:

```bash
hive up --repo ~/src/project --agents 3
hive up --repo ~/src/project --agents 3 --cmd "pi"
hive up --repo ~/src/project --agents 3 --cmd "claude --dangerously-skip-permissions"
hive up --repo ~/src/project --agents 3 --cmd "codex --full-auto"
```

### Session model
- one `tmux` session per repo or active workstream
- one window for control/status
- one window per attached agent
- one window for logs / manual shell work

Example shape:

```bash
tmux new-session -d -s project
tmux new-window -t project -n control 'watch -n2 hive ls --repo ~/src/project'
tmux new-window -t project -n agent-01 'hive attach --repo ~/src/project 01'
tmux new-window -t project -n agent-02 'hive attach --repo ~/src/project 02'
tmux new-window -t project -n logs 'hive logs --repo ~/src/project 01'
```

## Phone UX Model

### Primary workflow
1. Open phone SSH client.
2. Connect to VPS via Tailscale.
3. Attach to the relevant `tmux` session.
4. Inspect status, attach to an agent, or tail logs.

### Typical tasks
- check whether an agent is still running
- inspect current output/logs
- attach to `pi` interactively
- attach to a Claude/Codex container shell
- kick off a new agent run with `hive up`
- stop/cleanup with `hive down`

### Good mobile clients
- iPhone/iPad: Blink, Termius
- Android: Termius, JuiceSSH, Termux + OpenSSH

If the chosen client supports `mosh`, use it. If not, plain SSH + `tmux` is still acceptable.

## Pi-Specific Notes
- `pi` is especially promising later because it has RPC mode, but RPC is not needed for this first step.
- If running `pi` inside `tmux`, use pi's recommended `tmux` extended-key setup so modified Enter works correctly.
- Keep the first remote workflow terminal-native; revisit pi RPC only after the VPS workflow proves valuable.

## Security Model

### MVP security posture
- no public HTTP surface
- no public web terminal
- no inbound agent-specific ports
- access only through Tailscale + SSH

### Authentication
- SSH keys only
- Tailscale device auth for phone and VPS
- agent provider credentials live on the VPS in the normal CLI auth locations

### Why this is acceptable
- much smaller attack surface than exposing a browser-accessible terminal
- avoids prematurely building and securing a custom control API

## Operational Model

### Start-up pattern
- `ssh` to VPS
- `cd ~/src/project`
- `hive up --repo ~/src/project --agents N --cmd "..."`
- create/attach `tmux` session

### Inspect pattern
- `hive ls --repo ~/src/project`
- `hive logs --repo ~/src/project 01`
- `hive attach --repo ~/src/project 01`

### Cleanup pattern
- `hive down --repo ~/src/project`

## MVP Implementation Steps

### Phase 1: basic remote shell path
- provision VPS
- install Docker, Nix, Tailscale, tmux
- clone dotfiles repo
- verify `hive` works on the VPS
- verify phone can `ssh` in over Tailscale
- verify `tmux` works comfortably from the chosen phone client

Exit criteria:
- from phone, attach to VPS and resume a `tmux` session successfully

### Phase 2: remote agent runtime
- run `hive up` successfully on the VPS for one repo
- attach to one agent container from phone
- confirm worktree isolation and cleanup still work remotely
- test with at least one real agent runtime (`pi` or Claude Code)

Exit criteria:
- from phone, start, inspect, and stop one agent run end-to-end

### Phase 3: multi-agent workflow
- run multiple agents for the same repo
- establish a stable `tmux` layout / naming convention
- document the preferred daily commands
- test reconnect/disconnect behavior under normal phone network conditions

Exit criteria:
- from phone, manage at least 2-3 concurrent agents without confusion

### Phase 4: quality-of-life improvements
Possible follow-ons once the base flow is proven:
- `mosh`
- small helper scripts for tmux session creation
- notifications on completion/failure
- a small control-plane API
- pi RPC mobile UI later

## Concrete Follow-Up Work

### Small repo additions that may be worth doing
- `bin/hive-tmux` or similar helper to create a standard `tmux` layout for a repo
- VPS bootstrap notes or a dedicated plan for the chosen host distro
- a short cheatsheet for phone-first operations

### Not yet required
- custom app
- web terminal
- chat bot
- `pi` RPC supervisor
- vendor cloud integrations

## Open Questions
1. Which VPS distro is the right MVP target: Ubuntu/Debian + Nix, or NixOS from the start?
2. Which phone SSH client is good enough in practice for long-running agent work?
3. Do Claude/Codex auth flows behave cleanly on the VPS, or should `pi` be the first validated runtime?
4. Is `mosh` actually needed, or is `ssh` + `tmux` already sufficient over Tailscale?
5. Should the first ergonomic improvement be notifications, or a tmux-layout helper?

## Recommendation Summary
Build the simplest private remote path first:
- VPS
- Tailscale
- SSH
- tmux
- `hive`

Treat this as the proving ground. If it becomes a real daily workflow, then add a thin control layer on top rather than replacing the foundation.
