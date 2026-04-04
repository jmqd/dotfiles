# dotfiles

```bash
find ~ -name ".*" -maxdepth 1
```

## bootstrap

```bash
# Fresh macOS bootstrap:
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://raw.githubusercontent.com/jmqd/dotfiles/master/bin/bootstrap-macos.sh | bash
```

```bash
# Existing checkout with Home Manager (macOS or Linux):
mkdir -p ~/src
git clone https://github.com/jmqd/dotfiles.git ~/src/dotfiles
bash ~/src/dotfiles/bin/hm-switch.sh
```

```bash
# NixOS host rebuild (jmws):
mkdir -p ~/src
git clone https://github.com/jmqd/dotfiles.git ~/src/dotfiles
sudo nixos-rebuild switch --flake ~/src/dotfiles#jmws
```

```bash
# Optional private/personal follow-on step:
# only recommended if your name is "Jordan McQueen" ;)
bash ~/src/dotfiles/bin/link-private-data.sh
```

Home Manager is the canonical path for user-facing config. The private-data linker is only
for the small set of personal files that still live outside the public flake.

## git hooks

```bash
bash ~/src/dotfiles/bin/setup-git-hooks.sh
```

## nix tooling

```bash
# Enter a dev shell with gitleaks/shellcheck/shfmt and bootstrap deps
# (git/python3/awscli2)
nix develop

# Run the repo's lightweight automated checks
nix flake check

# Regenerate the pi package lockfile with flake-pinned Node/npm
nix develop .#pi-packaging -c bash -lc 'cd pkgs/pi && npm install --package-lock-only --ignore-scripts'

# Build or run the locally packaged pi coding agent
nix build .#pi
nix run .#pi

# Build or run the local flow jm.dev personal CLI
nix build .#flow
nix run .#flow -- --help

# Run credential-pattern lint manually
nix run .#secrets-lint
```

## direnv

```bash
# After Home Manager enables direnv + nix-direnv:
cd ~/src/dotfiles
direnv allow

# After that, entering this repo should auto-load the flake dev environment.
```

## home manager

```bash
# Apple Silicon macOS (uses current user/home)
HM_BOOTSTRAP_USER="$USER" nix run github:nix-community/home-manager -- switch --impure --flake ~/src/dotfiles#macos-aarch64

# Intel macOS (uses current user/home)
HM_BOOTSTRAP_USER="$USER" nix run github:nix-community/home-manager -- switch --impure --flake ~/src/dotfiles#macos-x86_64

# Linux x86_64
nix run github:nix-community/home-manager -- switch --flake ~/src/dotfiles#linux-x86_64

# Linux aarch64
nix run github:nix-community/home-manager -- switch --flake ~/src/dotfiles#linux-aarch64
```

## home manager backup mode

```bash
# Default path: auto-detects this machine and backs up conflicting files with
# the suffix ".hm-backup"
bash ~/src/dotfiles/bin/hm-switch.sh

# Override the suffix if you want a different backup extension
HM_BACKUP_EXT=pre-hm bash ~/src/dotfiles/bin/hm-switch.sh
```

For standalone Home Manager, the backup behavior is a command-line flag
(`-b <extension>`), not a persistent flake option. This wrapper makes it the
default entrypoint for switching on this repo.
