# Nixification Plan

## Goal
Adopt a single flake-based setup for dotfiles that works across:
- NixOS hosts (system + user config)
- macOS hosts using Nix package manager (user config first)

Primary objective is maximum sharing via Home Manager, with host/platform-specific modules only where needed.

## Recommended Architecture
Use one repository and one `flake.nix` with three layers:
1. Shared Home Manager modules: shell, git, tmux, editor, CLI tools, dotfiles.
2. Platform-specific Home Manager modules:
- Linux-only HM modules (X11/i3-related user config, Linux paths, etc).
- Darwin-only HM modules (macOS paths and integrations).
3. Host-specific system configs:
- `nixosConfigurations.<host>` for NixOS-only concerns (systemd, ssh service policy, boot, hardware, i3/system packages).
- Optional `darwinConfigurations.<host>` later if `nix-darwin` is adopted.

## Why This Approach
- High config reuse: most dotfiles and tooling stay in shared HM modules.
- Low risk macOS adoption: standalone Home Manager does not require full system takeover.
- Clean NixOS support: NixOS modules continue to own system-level concerns.
- Future-proof: can add `nix-darwin` without reworking shared modules.

## Flake Shape (Target)
```text
.
├── flake.nix
├── flake.lock
├── home/
│   ├── modules/
│   │   ├── shared/
│   │   ├── linux/
│   │   └── darwin/
│   └── hosts/
│       ├── jmq@<mac-host>.nix
│       └── jmq@<linux-host>.nix
├── nixos/
│   ├── configuration.nix
│   ├── hardware-configuration.nix
│   └── hosts/
│       └── <nixos-host>.nix
└── plans/
    └── nixification.md
```

## Phased Execution

### Phase 0: Baseline and Constraints
- Inventory existing configs and scripts used on new machine bootstrap.
- Decide initial package source policy (`nixpkgs` stable channel pin).
- Define host naming convention (`<user>@<hostname>` and system host IDs).

Exit criteria:
- Confirmed list of shared vs platform-specific behavior.

### Phase 1: Introduce Flake + Home Manager Skeleton
- Add `flake.nix` and inputs (`nixpkgs`, `home-manager`; `nix-darwin` optional but not required now).
- Create HM shared module scaffold and one host config for each platform.
- Keep existing non-Nix bootstrap files during migration, but make flake path first-class.

Exit criteria:
- `home-manager switch --flake .#<home-manager-target>` works on at least one machine.

### Phase 2: Migrate Shared Dotfiles to Home Manager
- Move `.zshrc`/`.bashrc` logic into HM-managed shell programs where practical.
- Migrate git, tmux, and common CLI packages.
- Migrate non-program-managed files (`home.file` / `xdg.configFile`) as needed.

Exit criteria:
- Core shell + git + tmux experience managed by HM and reproducible.

### Phase 3: Wire NixOS Hosts
- Add/normalize `nixosConfigurations.<host>` in flake outputs.
- Integrate Home Manager via NixOS module on Linux hosts.
- Move system-specific config from ad hoc scripts into NixOS modules where appropriate.

Exit criteria:
- `sudo nixos-rebuild switch --flake .#<nixos-host>` fully provisions a Linux machine.

### Phase 4: macOS Hardening
- Keep standalone HM path as default for macOS.
- Optionally add `nix-darwin` only if system-level macOS declarative management is desired.
- If added, keep user modules shared; only lift true system settings into darwin modules.

Exit criteria:
- macOS host can be rebuilt consistently with either HM-only or HM + darwin.

### Phase 5: Cleanup + Documentation
- Update install docs for each supported host type.
- Remove obsolete imperative setup steps once equivalents are proven.
- Add explicit recovery and rollback notes.

Exit criteria:
- README migration docs reflect current bootstrap flow.

## Operations and Commands

NixOS host rebuild:
```bash
sudo nixos-rebuild switch --flake .#<host>
```

macOS host (standalone Home Manager):
```bash
home-manager switch --impure --flake .#macos-<arch>
```

macOS host (if using nix-darwin):
```bash
sudo darwin-rebuild switch --flake .#<host>
```

Update inputs intentionally:
```bash
nix flake lock --update-input nixpkgs
nix flake lock --update-input home-manager
```

## Shared vs Host-Specific Rules
- Shared first: anything that is user-scoped and cross-platform goes into shared HM modules.
- Platform module second: only when behavior differs between Linux and Darwin.
- Host module last: only for machine-specific state (paths, hardware, local overrides).

## Initial Deliverables
1. `flake.nix` with `nixosConfigurations` and `homeConfigurations` outputs.
2. HM shared modules for shell, git, tmux, package set.
3. One working NixOS host target and one working macOS host target.
4. Updated bootstrap documentation with exact command per host type.

## Open Decisions
- Whether to adopt `nix-darwin` in phase 1 or postpone until phase 4.
- Whether to use Home Manager as NixOS module everywhere on Linux (recommended) or standalone on some Linux hosts.
- How aggressively to convert legacy dotfiles vs keep some as file assets under HM.
