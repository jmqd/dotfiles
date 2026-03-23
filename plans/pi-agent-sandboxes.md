# pi Agent Sandboxes Plan

## Goal
Create an easy way to spin up `N` isolated pi agents for the same repo on Linux, with:
- a separate working tree per agent
- an isolated shared Nix store/daemon that does **not** use the host `/nix/store`
- the repo dev environment available inside each sandbox so tools work without manual setup
- permission-gating friction removed because the container boundary is the real safety mechanism
- both headless orchestration and optional human interaction with an individual agent

## Design Priorities
1. **Isolation first**: agents should not touch the host repo checkout or host `/nix/store`.
2. **Fast spin-up**: avoid rebuilding the same dev environment per agent.
3. **Cheap parallelism**: N agents should share immutable artifacts where safe.
4. **Good ergonomics**: starting a fleet should be one command.
5. **Debuggability**: it should be easy to attach to one agent/container when something goes wrong.

## Recommended Architecture

### 1. Repo source model: bare mirror + per-agent worktrees
Do **not** create worktrees directly from the live repo checkout.

Instead:
- maintain a local bare mirror, e.g.:
  - `~/.local/share/pi-agent-fleet/repos/dotfiles.git`
- refresh it from the source repo via `git fetch`
- create per-agent detached worktrees from that mirror, e.g.:
  - `~/.local/share/pi-agent-fleet/worktrees/dotfiles/agent-01`
  - `~/.local/share/pi-agent-fleet/worktrees/dotfiles/agent-02`

Why:
- avoids mutating the live working tree
- avoids sharing the live repo’s `.git/worktrees` admin state
- makes cleanup and fleet lifecycle simpler

### 2. Nix isolation model: one dedicated daemon/store for the fleet
Use a dedicated writable Nix daemon/store for the fleet, separate from the host store.

Suggested shape:
- one long-lived "store daemon" container or sandbox root
- its `/nix` lives on a dedicated volume/subvolume/image under something like:
  - `/var/lib/pi-agent-fleet/nix-store/`
- all agent sandboxes mount that store’s `/nix/store` **read-only**
- agents talk to the dedicated daemon socket, not the host daemon

Why:
- avoids polluting the host store
- shares realized closures across all agents
- keeps agent sandboxes mostly immutable except for their worktree/tmp/cache areas

### 3. Agent runtime: per-agent `systemd-nspawn` container
Run each agent in its own `systemd-nspawn` machine.

Each agent gets:
- its own rootfs / writable overlay
- its own worktree bind-mounted writable
- read-only bind of the shared fleet `/nix/store`
- access to the fleet Nix daemon socket
- isolated `$HOME`, cache dirs, session dirs, and temp dirs

Why `systemd-nspawn`:
- integrates well with `machinectl`
- supports bind mounts cleanly
- good fit for "many lightweight Linux sandboxes"
- easier to inspect/attach than more opaque solutions

## Suggested Interaction Model

### Default: headless control via pi RPC mode
Run pi inside each sandbox as:
```bash
pi --mode rpc --no-session
```

Then build a small host-side controller that:
- starts/stops agents
- sends prompts to one or many agents
- collects streamed events/results
- can steer/follow-up/abort individual agents
- records logs and results per agent

Why:
- better for orchestration than trying to multiplex many TUIs
- pi already supports RPC mode for subprocess integration
- a host controller can later provide its own TUI/web UI if desired

### Optional: interactive attach for one agent
Also support attaching to a single sandbox for direct debugging.

Possible modes:
- `machinectl shell <agent>` for a shell inside the container
- run pi interactively in a tmux pane inside the sandbox for one-off debugging
- provide a helper like:
  - `fleet attach agent-03`
  - `fleet logs agent-03`

Recommended approach:
- **RPC for orchestration**
- **attach/shell for debugging**

## Dev Environment Strategy
The repo should feel "ready to use" inside each agent.

Recommended ordering:
1. make the dev environment a first-class flake entrypoint
2. prewarm/build it once in the dedicated fleet store
3. launch pi commands through that environment

Likely entrypoints:
- `nix develop <repo> -c pi ...`
- or if using `devenv`, `devenv shell -- pi ...`

For the first implementation, prefer:
- `nix develop -c ...`

Why:
- lower integration risk
- aligns with the current repo’s flake dev shell
- easy to pre-build in the shared dedicated store

If `devenv` becomes the main environment later, the launcher can swap to that without changing the rest of the architecture.

## Permission Model
There does **not** appear to be a documented built-in global pi flag specifically for "skip all permission prompts".

So the recommended model is:
- treat the container boundary as the real safety boundary
- do **not** load permission-gating extensions in the sandboxed fleet runtime
- or add a custom flag/extension mode such as:
  - `--trusted-sandbox`
  - which auto-allows permission checks in your own gate extensions

Recommendation:
- keep the host/default pi runtime conservative
- create a separate fleet runtime profile that is permissive because the container is the protection layer

## Proposed CLI Shape
Longer-term, add a small wrapper, maybe something like:

```bash
bin/pi-fleet up --repo ~/src/dotfiles --agents 4
bin/pi-fleet prompt agent-01 "review the uncommitted changes"
bin/pi-fleet prompt --all "find dead code"
bin/pi-fleet steer agent-02 "stop and focus on tests"
bin/pi-fleet attach agent-03
bin/pi-fleet logs agent-04
bin/pi-fleet down
```

Possible internals:
- `fleet up`
  - refresh bare mirror
  - create/update worktrees
  - ensure dedicated store daemon is running
  - prewarm dev env closure
  - start `N` nspawn containers
  - launch pi in RPC mode in each container
- `fleet prompt`
  - send RPC `prompt` to one/all agents
- `fleet attach`
  - attach shell or interactive pi session to a chosen agent
- `fleet down`
  - stop machines, optionally keep worktrees/store warm

## Storage / State Layout
Suggested local state:
```text
~/.local/share/pi-agent-fleet/
├── repos/
│   └── dotfiles.git/
├── worktrees/
│   └── dotfiles/
│       ├── agent-01/
│       ├── agent-02/
│       └── ...
├── sessions/
│   ├── agent-01/
│   ├── agent-02/
│   └── ...
├── logs/
│   ├── agent-01.log
│   └── ...
└── runtime/
    ├── sockets/
    └── metadata/
```

Dedicated fleet Nix store/state:
```text
/var/lib/pi-agent-fleet/
└── nix/
    ├── store/
    ├── var/
    └── daemon-socket/
```

## MVP Recommendation
Keep the first slice small.

### MVP v1
- one dedicated fleet Nix daemon/store
- one agent container
- one worktree from a local bare mirror
- pi launched via `nix develop -c pi --mode rpc --no-session`
- simple host script to:
  - start agent
  - send one prompt
  - stream logs
  - attach shell

### MVP v2
- multiple agents
- shared worktree provisioning logic
- basic orchestration commands (`prompt`, `abort`, `logs`, `attach`)

### MVP v3
- broadcast prompts to multiple agents
- aggregate results
- basic scheduler/queueing
- optional specialized agent roles

## Key Tradeoffs

### `systemd-nspawn` vs alternatives
**Recommend `systemd-nspawn` first**.

Pros:
- integrates naturally with Linux/systemd
- machine lifecycle is easy to observe and control
- good bind-mount ergonomics
- easy to attach/debug

Cons:
- more Linux/systemd-specific
- you will need to think carefully about shared socket/store mounts

### Shared dedicated store vs binary cache
Your proposed shared read-only store + dedicated daemon is workable and probably the right first design.

Alternative:
- each agent has its own isolated store
- populate from a private binary cache

That alternative is cleaner in some ways, but heavier and slower at first.

Recommendation:
- start with **one dedicated store daemon + read-only store mounts**
- only move to a binary cache model if daemon/socket sharing becomes awkward

### Interactive TUI vs RPC
**Recommend RPC as the control plane**.

Use interactive attach only for debugging.

Why:
- multiple TUIs are awkward to orchestrate
- RPC composes better with a supervisor, queue, or custom UI
- pi already supports steer/follow-up/abort/state via RPC

## Open Questions
- Should the dedicated fleet store live in a persistent host directory, a loopback image, or a special daemon container root?
- Should agent root filesystems be ephemeral per run, or cached between runs?
- Do you want one global warm fleet store, or one per repo/project?
- Should worktrees be recreated per run, or reused and hard-reset/cleaned?
- Should the host controller be a shell script first, or a small typed program (Node/Rust)?
- Do you want "attach" to mean a shell, an interactive pi TUI, or both?
- Do you want the fleet runner to support specialized roles/prompts from day one, or only generic workers initially?

## Recommended First Implementation Slice
1. write a small design-constraining script for one agent only
2. use a local bare mirror instead of the live repo
3. run one `systemd-nspawn` agent with an isolated worktree and isolated HOME
4. run pi in RPC mode inside that agent
5. drive it from a very small host controller
6. only after that works, introduce the dedicated fleet Nix daemon/store

Reason:
- the hardest conceptual parts are lifecycle and interaction
- if those are wrong, the dedicated-store work will be wasted churn
- once the one-agent path is clean, scaling to `N` agents is much easier

## Follow-up Implementation Targets
Potential repo additions later:
- `bin/pi-fleet`
- `nixos/modules/pi-agent-fleet.nix`
- `nixos/modules/pi-agent-store.nix`
- `plans/pi-agent-sandboxes.md`
- optional pi extension/profile for permissive trusted-sandbox mode

## References
- pi RPC mode docs: `docs/rpc.md`
- pi extension docs: `docs/extensions.md`
- pi sandbox example: `examples/extensions/sandbox/`
- pi remote execution example: `examples/extensions/ssh.ts`
