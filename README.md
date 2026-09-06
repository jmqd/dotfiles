# dotfiles

```bash
find ~ -name ".*" -maxdepth 1
```

## flow search

User-facing documentation for the shipped `flow search` feature lives in
[`docs/flow-search.md`](docs/flow-search.md).

## OMP phone

[`projects/omp-phone`](projects/omp-phone) contains a shareable OMP extension,
Rust companion, and dependency-free browser UI. It controls existing terminal
sessions through OMP's public extension API; it never launches a second agent
against a session. Requires OMP 18.1.11 or newer.

Home Manager installs the companion, registers the extension alongside existing
extensions, and starts a user service on macOS/Linux when custom CLI packages
are enabled. Set the **machine-specific** HTTPS URL and authorization in your host module:

```nix
services.omp-phone = {
  publicUrl = "https://your-machine.your-tailnet.ts.net/omp/";
  allowedTailnetUsers = [ "you@example.com" ];
  tailnetCapability = "example.com/cap/omp-phone";
};
```

The `macos-aarch64` profile in [`home/hosts/jmq-macos.nix`](home/hosts/jmq-macos.nix)
uses the private URL `https://jordans-macbook-pro.taild6d9b.ts.net/omp/`, login
`j@jm.dev`, and capability `jm.dev/cap/omp-phone`. Its policy destination is
`100.94.227.118`. Use those values in the grant and Serve command below.
Other machines need their own hostname and destination. The `publicUrl` option
names the browser-facing URL, including `/omp/`; it does not make the service public.

HTTPS mode requires Tailscale 1.92+ and a member-only application capability.
Merge a grant like this into the **existing** tailnet policy, replacing the
destination with this machine's Tailscale IP and the capability with your configured
name. Do not replace the whole policy:

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["100.64.0.10"],
      "ip": ["tcp:443"],
      "app": {
        "example.com/cap/omp-phone": [{"access": true}]
      }
    }
  ]
}
```

Never grant this capability to `*` or `autogroup:shared`. A login header alone
does not prove private-tailnet membership: shared-device users also receive one.
Both the capability and exact login must match; tagged nodes are intentionally
denied. ACLs/grants are additive: audit and narrow any other rule granting shared
outsiders access to this machine's TCP 443. Adding the grant above does not revoke
access granted elsewhere. Keep the node unshared until that policy audit is complete.

Apply Home Manager, open a new shell, and restart the OMP sessions you want to
expose. Without `publicUrl`, only direct localhost access at `/omp/` is accepted;
forwarded requests are rejected. Connect Tailscale deliberately: a stopped client
may retain an exit-node preference. Configure **Serve, never public Funnel**:

```sh
tailscale serve --bg --https=443 --set-path=/omp --accept-app-caps=example.com/cap/omp-phone http://127.0.0.1:8787/omp
tailscale serve status --json
omp-phone pair
```

Keep `/omp` in **both** the Serve mount and proxy target: Serve strips the mount
prefix before adding the target path. This leaves `/` and other paths available
for sibling services. The companion redirects `/omp` to `/omp/`, and does not
serve its UI or API at the hostname root.

The pairing cookie, installed-app identity and service worker are scoped to
`/omp/`; notification clicks only reuse OMP tabs. Paths still share a browser
origin, so only put trusted apps on the same HTTPS hostname and port.

When upgrading a root-mounted installation, disable its notifications first,
remove only its old OMP root mapping from Serve, then re-pair and reinstall the
OMP Home Screen app using the new URL. Do not reset unrelated Serve mappings.

Open the pairing link on your phone with Tailscale connected. Treat the link as a
password; its token is exchanged for an HttpOnly cookie and removed from the URL.
On iPhone, add the page to the Home Screen before enabling notifications.
Serve manages TLS; enabling HTTPS certificates may require tailnet-admin approval.
Confirm the proxy is tailnet-only, with no enabled `AllowFunnel` entry. Never add
a WAN/LAN reverse proxy or port forward to the companion. This module does not
change live Tailscale settings, grant capabilities, or enable certificates.

The HTTP listener is fixed to `127.0.0.1`; extension control uses
`extension.sock` (0600) inside the private state directory (0700), not HTTP or
WebSocket. Every HTTPS route, including assets, health, login and SSE, requires
the authoritative Serve login and membership capability. Missing authorization,
duplicate identity headers and Funnel requests fail closed even with a valid
pairing cookie. Local processes can impersonate the loopback proxy, so the host
itself remains trusted; browser pairing is still required for API access.
Only the same OS user/root can reach extension control or read the pairing token.

On macOS, Nix pins the official standalone Tailscale installer and supplies a CLI
wrapper for its installed GUI. See [macOS migration](#tailscale-on-macos) before
replacing an App Store installation. Home Manager switches only check installation
state; the privileged installer runs separately, when explicitly requested.

Idle sessions appear first, newest state change first. A working→idle transition
sends one Web Push notification; connecting/reconnecting an idle session does not.
Push uses outbound HTTPS through Apple/Google/Mozilla infrastructure; encrypted
payloads contain machine/session titles but no conversation text. Replies while
busy are queued as follow-ups. Stop
interrupts the existing agent. Questions and approvals remain terminal-only.
The browser shows recent user/assistant text and tool output, not full history or
image previews. Disconnected sessions disappear; stale replies are rejected.

`/phone` reports the current terminal's connection status. Set
`OMP_PHONE_DISABLED=1` before starting OMP to exclude a session. Runtime secrets
and subscriptions live under `~/.local/state/omp-phone`, never in the Nix store.
Restarting the companion requires pairing the browser again; push subscriptions
persist. Disable notifications in the browser before signing out to stop them.

For development without activating Home Manager:

```sh
cargo run --manifest-path projects/omp-phone/Cargo.toml -- serve
# In another terminal:
omp -e ./projects/omp-phone
# In another terminal; open the printed localhost /omp/ link:
cargo run --manifest-path projects/omp-phone/Cargo.toml -- pair
```

Run `cargo test --manifest-path projects/omp-phone/Cargo.toml` for the focused
tailnet authorization, pairing, session-ownership, state-transition and push-endpoint checks.
`nix build .#omp-phone` builds the package; new files must be tracked for Git-flake
evaluation. To use the extension outside this repository, copy this project,
build/install its Rust companion, and run `omp plugin install /absolute/path/to/omp-phone`.
Alternatively, import its `home-module.nix` and enable `services.omp-phone.enable`.
Do not register it through both mechanisms.

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

Verify daemon access and effective cache settings after setup:

```bash
nix store info --json
nix config show substituters
nix config show trusted-public-keys
nix config show require-sigs
```

The cache URL and `nix-community.cachix.org-1` signing key should appear, and
`require-sigs` should remain `true`. `"trusted": 0` in the daemon response is
expected for an ordinary client: using the configured cache does not require
granting that client administrative Nix privileges.

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

Validation sources are filtered in `flake.nix`: formatting checks include their
listed scripts or all discovered Nix files; targeted tests include their helpers
and fixtures. Unrelated edits can reuse those check results. When a test gains a
helper or fixture, add it to that check's `checkSource` list. Secret scanning
intentionally covers the entire tracked repository and is not narrowed.

Agent writing guidance is defined once in [`home/writing-style.nix`](home/writing-style.nix).
Home Manager substitutes it verbatim for `@writingStyle@` in `.in` templates,
then installs the normal filenames without `.in`. This covers global instructions
for OMP, Pi, Claude, and Codex; commit and review prompts; and Git's commit
template. OMP's `PERSONALITY.md` uses the same string without replacing its tool
or workflow instructions. Edit the Nix string to change the shared wording, then
apply it with `bin/hm-switch.sh`. Caveman mode requires an explicit request.

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

## tailscale on macOS

`home/darwin/tailscale.nix` pins the official signed, notarized standalone `.pkg`
for Apple Silicon and Intel. The official installer places the GUI in
`/Applications/Tailscale.app`; the Nix `tailscale` command runs that app's bundled
CLI. There is no separate `tailscaled` service or Nix-store GUI installation.

Home Manager installs `tailscale-install`, retains its pinned package in the Nix
closure, and runs a **read-only** installation check during activation. Missing,
conflicting, or mismatched installations produce a warning without failing the
switch. Only an explicit `tailscale-install` invokes Apple's installer via sudo.
It checks package signing/notarization and refuses the App Store variant,
unexpected target bundles/symlinks, detected duplicate apps, and running
CLI-only daemons. Installation can restart Tailscale and interrupt the VPN.

### migrating from the App Store

1. **Before uninstalling**, switch to this configuration to make both commands
   and the pinned installer available:
   ```bash
   bash ~/src/dotfiles/bin/hm-switch.sh
   tailscale-install --check
   ```
   The check exits 1 while the App Store app is present; no app or VPN changes
   are made by this check.
2. Follow [Tailscale's variant migration instructions](https://tailscale.com/docs/concepts/macos-variants):
   quit Tailscale, remove the App Store app, empty Trash, and **reboot before
   installing the standalone variant**. Do not manually delete settings or
   Keychain entries. The helper never performs this removal or reboot.
3. After reboot, run `tailscale-install`. Enter your administrator password for
   the official package installer, approve macOS's system-extension prompts,
   and sign in if requested.
4. Run `tailscale-install --check`, `tailscale version`, and `tailscale status`.
   Verify the node's DNS name/IP and your exit-node choice: identity and settings
   are not guaranteed to survive a variant change. Update the machine-specific
   OMP URL and tailnet grants if necessary, then follow the private Serve setup
   above. Installing the app does not configure OMP Serve or tailnet policy.

For updates, change both `version` and `hash` in `home/darwin/tailscale.nix`,
switch Home Manager, then run `tailscale-install`. The pin is independent of
`flake.lock`; `nix flake update` alone does not advance it. The helper installs the
exact pin, including replacing a newer installed version with an older pin.
Disable automatic app updates in Tailscale's settings if Nix should be the sole
version authority; otherwise the activation check reports any version drift.

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
