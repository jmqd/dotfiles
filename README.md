# dotfiles

```bash
find ~ -name ".*" -maxdepth 1
```

## install

```bash
# only recommended if your name is "Jordan McQueen" ;)
mkdir -p ~/src
git clone https://github.com/mcqueenjordan/dotfiles.git ~/src/dotfiles
nix develop ~/src/dotfiles -c bash ~/src/dotfiles/bin/install.sh
```

## git hooks

```bash
bash ~/src/dotfiles/bin/setup-git-hooks.sh
```

## nix tooling

```bash
# Enter a dev shell with gitleaks/shellcheck/shfmt and bootstrap deps
# (git/python3/awscli2)
nix develop

# Regenerate the pi package lockfile with flake-pinned Node/npm
nix develop .#pi-packaging -c bash -lc 'cd pkgs/pi && npm install --package-lock-only --ignore-scripts'

# Build or run the locally packaged pi coding agent
nix build .#pi
nix run .#pi

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

## home manager (macOS)

```bash
# Apple Silicon
nix run github:nix-community/home-manager -- switch --flake ~/src/dotfiles#jmq@macos-aarch64

# Intel macOS
nix run github:nix-community/home-manager -- switch --flake ~/src/dotfiles#jmq@macos-x86_64
```

## home manager backup mode

```bash
# Default path: auto-detects this Mac and backs up conflicting files with
# the suffix ".hm-backup"
bash ~/src/dotfiles/bin/hm-switch.sh

# Override the suffix if you want a different backup extension
HM_BACKUP_EXT=pre-hm bash ~/src/dotfiles/bin/hm-switch.sh
```

For standalone Home Manager, the backup behavior is a command-line flag
(`-b <extension>`), not a persistent flake option. This wrapper makes it the
default entrypoint for switching on this repo.
