# NixOS Flake System Migration Plan

## Goal
Migrate the remaining Linux machine setup from the old ad hoc `nixos/configuration.nix` + installer flow into first-class flake outputs.

Primary objectives:
- add `nixosConfigurations` to this repo
- move real system config into NixOS modules
- move the embedded Home Manager user config out of `nixos/configuration.nix` and into the existing `home/` tree
- keep generated hardware config separate and host-specific
- retire the old `/etc/nixos/configuration.nix` symlink workflow

## Current State
Today the repo has:
- `homeConfigurations` in `flake.nix`
- no `nixosConfigurations` yet
- old Linux system config in `nixos/configuration.nix`
- generated hardware config in `nixos/hardware-configuration.nix`
- an embedded Home Manager block inside `nixos/configuration.nix`
- old bootstrap behavior that still symlinked Linux desktop/user files manually

## Source Inventory

### System config currently living in `nixos/configuration.nix`
These belong in a NixOS flake host output:
- boot loader and EFI config
- hostname, timezone, Nix settings, GC settings
- unfree/Nixpkgs policy
- font packages
- PAM login limits
- SSH, tailscale, timesyncd
- X11/i3 session wiring
- virtualization/libvirt/SPICE
- kernel modules and modprobe config
- NVIDIA/graphics/video driver setup
- NixOS-level program toggles (`steam`, `dconf`, `nix-ld`, `zsh`)
- Linux user definition for `jmq`
- system package set

### User config currently embedded inside `nixos/configuration.nix`
These should move into `home/linux.nix` and related Home Manager modules:
- `home.sessionVariables`
- `home.shellAliases`
- Linux-only user packages
- user programs (`chromium`, `google-chrome`, `rofi`, `nix-index`, `emacs`, `i3status-rust`)
- `services.emacs`

### Old bootstrap-managed user files not yet migrated to Home Manager modules
From the historical bootstrap flow and repo contents:
- `.Xmodmap`
- `.Xresources`
- `.i3/config`
- `.i3/status_bar.toml`
- `.config/i3status/i3status.py`
- `autorandr.profile`
- `bin/i3-renameworkspaces.pl` (migrate or delete)
- `.doom.d/config.el`
- `.doom.d/init.el`
- `.doom.d/packages.el`

### Private/bootstrap items that should not be copied directly into the public flake
- `~/.env`
- `~/.git-credentials`
- `~/.password-store`
- `~/.gpg-id`
- private-data sync steps from `bin/link-private-data.sh`

These likely belong in a private module/bootstrap layer, `sops-nix`, `agenix`, or a separate manual bootstrap step.

## Recommended Target Layout
```text
.
├── flake.nix
├── home/
│   ├── common.nix
│   ├── linux.nix
│   ├── darwin.nix
│   ├── git.nix
│   ├── tmux.nix
│   ├── zsh.nix
│   ├── ...
│   ├── linux-desktop.nix          # new, optional
│   ├── doom.nix                   # new, optional
│   └── hosts/
│       ├── jmq-linux.nix
│       └── jmq-macos.nix
├── nixos/
│   ├── hosts/
│   │   └── jmws.nix               # new flake host entrypoint
│   ├── modules/
│   │   ├── base.nix               # core NixOS settings
│   │   ├── desktop-i3.nix         # X11/i3 session wiring
│   │   ├── nvidia.nix             # GPU/graphics config
│   │   ├── virtualization.nix     # libvirt/SPICE/vm tooling
│   │   └── packages.nix           # system-level package set if retained
│   └── hardware/
│       └── jmws.nix               # renamed/generated hardware config
└── plans/
    └── nixos-flake-system-migration.md
```

Notes:
- The exact module split can be smaller or larger; the key point is separating host wiring from reusable concerns.
- `nixos/hardware-configuration.nix` can either stay where it is or be renamed to `nixos/hardware/jmws.nix`.

## Migration Checklist

### Phase 1: Add flake NixOS output
- [ ] Add `nixosConfigurations` to `flake.nix`
- [ ] Add host output `nixosConfigurations.jmws`
- [ ] Import the host’s hardware config from the flake output
- [ ] Use `home-manager.nixosModules.home-manager` from the flake input
- [ ] Stop relying on `<home-manager/nixos>` in the old config path
- [ ] Wire `home-manager.users.jmq = import ./home/hosts/jmq-linux.nix;`
- [ ] Verify `nix eval .#nixosConfigurations.jmws.config.networking.hostName`

### Phase 2: Extract system config from old `nixos/configuration.nix`
Move these into NixOS modules/host config:

#### Core host settings
- [ ] `networking.hostName = "jmws"`
- [ ] `time.timeZone = "Asia/Tokyo"`
- [ ] `system.stateVersion = "25.05"`
- [ ] `nix.gc.*`
- [ ] `nix.settings.allowed-users`
- [ ] `nix.settings.experimental-features`
- [ ] `nixpkgs.config.allowUnfree = true`
- [ ] `environment.pathsToLink = [ "/libexec" ]`

#### Boot / kernel / hardware
- [ ] `boot.loader.systemd-boot.enable`
- [ ] `boot.loader.efi.canTouchEfiVariables`
- [ ] `boot.kernelModules = [ "v4l2loopback" ]`
- [ ] `boot.extraModulePackages = [ v4l2loopback.out ]`
- [ ] `boot.extraModprobeConfig`
- [ ] NVIDIA settings
- [ ] graphics/video-driver settings
- [ ] review `hardware.opengl.*` vs current nixpkgs conventions during migration

#### Fonts / user / security
- [ ] font packages
- [ ] `security.pam.loginLimits`
- [ ] `users.users.jmq`

#### Services
- [ ] `services.openssh.enable`
- [ ] `services.tailscale.*`
- [ ] `services.timesyncd.enable`

#### Desktop / virtualization
- [ ] X11 enablement and i3 session wiring
- [ ] i3 extra packages (`dmenu`, `i3status`, `i3lock`, `i3wsr`)
- [ ] libvirt config
- [ ] SPICE config

#### NixOS-level programs
- [ ] `programs.nix-ld.*`
- [ ] `programs.steam.enable`
- [ ] `programs.dconf.enable`
- [ ] `programs.zsh.enable`

### Phase 3: Remove embedded Home Manager config from old system file
Move these into `home/linux.nix` or new HM modules:
- [ ] `home.sessionVariables`
- [ ] `home.shellAliases`
- [ ] Linux-only Home Manager packages
- [ ] `programs.chromium`
- [ ] `programs.google-chrome`
- [ ] `programs.rofi`
- [ ] `programs.nix-index`
- [ ] `programs.emacs`
- [ ] `programs.i3status-rust`
- [ ] `services.emacs`

Exit condition:
- the flake NixOS host imports HM cleanly
- there is no meaningful user config left embedded in old `nixos/configuration.nix`

### Phase 4: Triage old `environment.systemPackages`
Do not copy it wholesale.

Split the package list into:
- [ ] true NixOS system packages
- [ ] user-scoped Home Manager packages
- [ ] project/dev-shell tools

Specific review tasks:
- [ ] keep low-level host/admin tools only if they are genuinely machine-wide
- [ ] move everyday CLI tools and desktop apps to Home Manager
- [ ] move development-only toolchains to flake `devShells` where practical
- [ ] remove duplicates already provided elsewhere (`git`, `fd`, `ripgrep`, etc.)

### Phase 5: Migrate remaining Linux desktop dotfiles into Home Manager
These are not NixOS system config, but they are still part of the old Linux setup.

- [ ] `.i3/config`
- [ ] `.i3/status_bar.toml`
- [ ] `.config/i3status/i3status.py`
- [ ] `.Xmodmap`
- [ ] `.Xresources`
- [ ] `autorandr.profile`
- [ ] decide whether `bin/i3-renameworkspaces.pl` should be migrated or archived

Suggested module split:
- [ ] `home/linux-desktop.nix` or equivalent
- [ ] optional `home/i3.nix`
- [ ] optional `home/x11.nix`
- [ ] optional `home/autorandr.nix`

### Phase 6: Migrate Doom config under Home Manager
- [ ] `.doom.d/config.el`
- [ ] `.doom.d/init.el`
- [ ] `.doom.d/packages.el`
- [ ] decide whether to manage Doom via raw `home.file` first or a more structured bootstrap flow

### Phase 7: Replace old imperative bootstrap/rebuild steps
- [ ] stop symlinking `nixos/configuration.nix` into `/etc/nixos/configuration.nix`
- [ ] stop depending on the old `<home-manager/nixos>` path
- [ ] document the flake-native rebuild command:
  - `sudo nixos-rebuild switch --flake ~/src/dotfiles#jmws`
- [ ] keep `bin/link-private-data.sh` only for private/bootstrap concerns, or retire it entirely once replaced

### Phase 8: Private/bootstrap layer
- [ ] decide how private secrets/config will be provisioned
- [ ] keep public flake free of plaintext secrets
- [ ] choose one of:
  - private overlay/module
  - `sops-nix`
  - `agenix`
  - explicit manual bootstrap

## Suggested File-by-File Move Map

### Move to flake NixOS host/modules
From old `nixos/configuration.nix`:
- boot loader
- Nix settings / GC
- hostname / timezone
- fonts
- PAM limits
- openssh / tailscale / timesyncd
- X11 / i3 session wiring
- virtualization / SPICE
- kernel modules / modprobe
- NVIDIA / graphics
- NixOS program toggles
- Linux user declaration
- any packages retained as true system packages

### Move to Home Manager modules
From the embedded HM block in old `nixos/configuration.nix`:
- session variables
- shell aliases
- Linux-only HM package list
- browser/rofi/emacs/nix-index/i3status-rust user programs
- `services.emacs`

From old installer-managed user files:
- i3/X11 files
- Doom files

### Keep host-specific and generated
- `nixos/hardware-configuration.nix` (or rename to `nixos/hardware/jmws.nix`)

### Keep out of the public flake
- secrets and cloud/bootstrap state

## Verification Checklist

### Early checks
- [ ] `nix eval .#nixosConfigurations.jmws.config.networking.hostName`
- [ ] `nix eval .#nixosConfigurations.jmws.config.system.stateVersion`
- [ ] `nix eval .#nixosConfigurations.jmws.config.users.users.jmq.shell`

### Dry evaluation/build checks
- [ ] `nix build .#nixosConfigurations.jmws.config.system.build.toplevel`
- [ ] `nix eval .#homeConfigurations."linux-x86_64".activationPackage.drvPath`

### Activation checks
- [ ] `sudo nixos-rebuild switch --flake ~/src/dotfiles#jmws`
- [ ] confirm HM activation still happens for user `jmq`
- [ ] confirm zsh, git, tmux, wezterm, pi config still land as expected
- [ ] confirm Linux desktop session still starts and i3 config loads
- [ ] confirm NVIDIA/libvirt/Steam/tailscale behavior still works

## Open Questions
- Should Linux desktop config stay mostly as `home.file` assets first, or be expressed more declaratively from day one?
- Which packages from the old giant `environment.systemPackages` list are still truly needed?
- Should Doom remain a raw checked-in config managed by Home Manager, or should Emacs bootstrap be redesigned too?
- Do you want one Linux host (`jmws`) only for now, or a reusable Linux-host pattern immediately?
- Should secrets/bootstrap remain manual for now, or do you want to fold in `sops-nix`/`agenix` as part of this migration?

## Recommended First Slice
If resuming later, start with the smallest coherent slice:
1. add `nixosConfigurations.jmws`
2. create a host module that imports hardware config + Home Manager
3. move only core system settings first
4. keep old package list mostly intact temporarily
5. once evaluation works, move the embedded HM block into `home/linux.nix`
6. only then start trimming packages and migrating i3/X11/Doom files
