# dotfiles

```bash
find ~ -name ".*" -maxdepth 1
```

## flow search

User-facing documentation for the shipped `flow search` feature lives in
[`docs/flow-search.md`](docs/flow-search.md).

## PostgreSQL

Home Manager runs a personal PostgreSQL 17 server after login on macOS and
Linux. The first service start initializes
`~/.local/share/postgresql/17`; later starts reuse that cluster. PostgreSQL
listens only on the private Unix socket at
`~/.local/share/postgresql/run`, not on TCP.

New shells inherit `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`, so the
default cluster is directly available:

```bash
pg_isready
psql
```

Inspect the service with `systemctl --user status postgresql` on Linux or
`launchctl print gui/"$UID"/org.nix-community.home.postgresql` on macOS.
Changing the pinned PostgreSQL major version intentionally selects a new data
directory; migrate the existing cluster before changing that pin.


## bootstrap

```bash
# Fresh macOS bootstrap:
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://raw.githubusercontent.com/jmqd/dotfiles/master/bin/bootstrap-macos.sh | bash
```

The macOS bootstrap downloads the Determinate Nix installer to a temporary file,
prints its SHA-256 hash, and then runs that file. To inspect the installer
without executing it, run the bootstrap with
`DOTFILES_DETERMINATE_NIX_VERIFY_ONLY=1`; it will print the installer path and
the exact `sh ... install --determinate` command to run after manual review.

```bash
# Existing checkout with Home Manager (macOS or standalone Linux):
mkdir -p ~/src
git clone https://github.com/jmqd/dotfiles.git ~/src/dotfiles
bash ~/src/dotfiles/bin/hm-switch.sh
```

The macOS bootstrap configures the [Nix community binary cache](https://nix-community.org/cache/)
in the daemon, where cache URLs and signing keys must be trusted. On an existing
Determinate Nix macOS installation, run this once:

```bash
sudo /bin/bash ~/src/dotfiles/bin/setup-nix-cache.sh
```

This preserves installer-managed `nix.conf` and existing custom settings, adds
`nix/cache.conf` through `nix.custom.conf`, and restarts the daemon when changed.
It retains default caches and signature verification without expanding
`trusted-users`. NixOS already declares this cache in its host configuration.

Raycast is the Option-Space launcher on macOS. If that shortcut was changed,
open **Raycast Settings → General** and set **Raycast Hotkey** to Option-Space;
Raycast does not provide a supported noninteractive hotkey setter. Home Manager
owns the running Raycast process so old Nix-store versions cannot compete for
the global shortcut. The agent uses `open -W -g`, not `-j` (launch hidden):
hidden launch can leave Raycast's window off-screen even when it receives
the hotkey. After changing the agent, run `bin/hm-switch.sh` to restart it.

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

Home Manager modules remain the canonical source of user-facing config, but
`jmws` applies them through `nixos-rebuild --flake`. The private-data linker is
only for the small set of personal files that still live outside the public
flake.

The private-data linker intentionally does not install `~/.git-credentials`.
Use SSH remotes or the platform Git credential helper instead. On macOS, Home
Manager configures `osxkeychain`; if a legacy plaintext `~/.git-credentials`
file exists, remove it and rotate any personal access tokens it contained.

## git hooks

```bash
bash ~/src/dotfiles/bin/setup-git-hooks.sh
```

The pre-push hook scans both the worktree and history across all local Git
refs. Removing a secret in a later commit does not make it safe to push;
rotate the credential and remove it from the outgoing history first.

## nix tooling

```bash
# Enter a dev shell with just/gitleaks/shellcheck/shfmt and bootstrap deps
# (git/python3/awscli2)
nix develop

# Run the repo's canonical lightweight automated checks
just check

# Equivalent lower-level command
nix flake check

# Audit pinned dependencies and report available upgrades or known residual
# upstream advisories
just audit-deps

# Build or run the pinned oh-my-pi agent (`pi` is kept as an alias)
nix build .#pi
nix run .#pi -- --version
nix run .#omp -- --version

# Build or run the local flow jm.dev personal CLI
nix build .#flow
nix run .#flow -- --help

# Run credential-pattern lint manually
nix run .#secrets-lint

# Periodically scan Git history for committed secrets. Current allowlists cover
# ignored local caches and old vendored oh-my-zsh dotenv sample-token docs.
bin/lint-secrets.sh --history
```

## Nix storage maintenance

Keep the current generation and four rollback generations for each user profile:

```bash
profiles="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles"
nix-env --profile "$profiles/home-manager" --delete-generations +5
nix-env --profile "$profiles/profile" --delete-generations +5
nix-store --gc
```

Generation pruning removes rollback points, not the active configuration. Garbage
collection removes only unreferenced store paths; discarded build results may need
to be downloaded or rebuilt later. Determinate Nix already runs automatic GC, so
do not add a competing scheduled collector. If macOS denies access to an old app
bundle, resolve App Management permission rather than changing store permissions.

Inspect project `rust-toolchain` files and `rustup override list` before using
`rustup toolchain uninstall VERSION`; different selectors such as `1.93` and
`1.93.0` are not interchangeable.

Home Manager installs Rust only when the requested compiler is missing and adds
missing components. An existing installation is not updated during a switch.
Run `just rust-update` (or `bin/bootstrap-rust.sh --update stable`) to update it
explicitly.

## direnv

```bash
# After Home Manager enables direnv + nix-direnv:
cd ~/src/dotfiles
direnv allow

# After that, entering this repo should auto-load the flake dev environment.
```

## home manager

Standalone Home Manager targets are for macOS and non-NixOS Linux only. `jmws`
is managed through `sudo nixos-rebuild switch --flake ~/src/dotfiles#jmws`.

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

The Home Manager activation hook will try to bootstrap a default Rust toolchain
via `rustup`. By default that step is best-effort so first activation can still
finish offline; set `HM_STRICT_RUST_BOOTSTRAP=1` if you want bootstrap failure
to abort the switch.

## home manager backup mode

This wrapper is only for standalone Home Manager, not NixOS hosts like `jmws`.

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
