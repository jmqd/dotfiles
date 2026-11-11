# TODO

## Current priorities
- [x] Add lightweight repo quality checks and a canonical `nix flake check` path.
- [ ] Audit the remaining `bin/` scripts and decide which should be exposed in Home Manager PATH, kept repo-local, or archived.
- [ ] Tighten bootstrap docs for macOS, Linux, NixOS, and the optional private-data follow-on flow.

## Private/bootstrap follow-ups
- [ ] Decide whether `bin/link-private-data.sh` should stay as a script or move into a private Home Manager layer.
- [ ] Keep `~/.env` provisioning explicit and documented.

## Security follow-ups
- [x] Ignore or relocate generated local auth/session files such as `home/.pi/agent/auth.json` so they cannot be accidentally committed if populated.
- [x] Make `bin/lint-secrets.sh` respect ignored local cache/build paths such as `emacs/var/` and add explicit gitleaks allowlists for known vendored sample-token false positives.
- [x] Add a periodic git-history secret scan target and document the current historical false positives from vendored `.oh-my-zsh/plugins/dotenv/README.md` examples.
- [x] Harden NixOS SSH settings explicitly in `nixos/hosts/jmws.nix` (`PasswordAuthentication`, `KbdInteractiveAuthentication`, `PermitRootLogin`, and firewall/Tailscale scoping).
- [x] Replace the private-data `.git-credentials` symlink with an OS-backed credential helper, encrypted provisioning, or a documented rotation policy.
- [x] Package Oracle through fixed-output Nix/npm dependencies instead of executing `npx -y @steipete/oracle@...` at runtime.
- [x] Review the macOS bootstrap `curl | sh` Determinate Nix installer path and add checksum/signature verification or a documented manual verification option.
- [x] Update `pkgs/flow` Rust dependencies to remove the cargo-audit yanked-crate warning for `fastrand 2.4.0` via `tempfile`.
- [ ] Confirm YubiKey serials are acceptable to publish, then register all personal YubiKeys in `home/yubikey.nix` with stable names/serials.
- [ ] Integrate YubiKeys into auth workflows across the repo and hosts: SOPS/secrets, SSH/GPG signing or encryption, sudo/PAM/login where appropriate, and recovery/backup-key procedures, with a bias toward mandatory 2FA everywhere.
- [ ] Track upstream fixes for `googleworkspace/cli v0.22.5`: cargo-audit reports `h2 0.4.13` (`RUSTSEC-2026-0258`, fixed in `>=0.4.16`), `quinn-proto 0.11.14` (`RUSTSEC-2026-0185`, fixed in `>=0.11.15`; `RUSTSEC-2026-0339`, `RUSTSEC-2026-0342`, fixed in `>=0.11.17`; `RUSTSEC-2026-0338`, `RUSTSEC-2026-0340`, fixed in `>=0.11.18`), `rustls 0.23.37` (`RUSTSEC-2026-0285`, fixed in `>=0.23.45`; `RUSTSEC-2026-0346`, `RUSTSEC-2026-0348`, `RUSTSEC-2026-0349`, fixed in `>=0.23.46`), and `rustls-webpki 0.103.10` (`RUSTSEC-2026-0104`, fixed in `>=0.103.13`; `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099`, fixed in `>=0.103.12`; `RUSTSEC-2026-0382` eMudhra intermediates, fixed in `>=0.103.16`). It verifies against the system store, which `home/tls.nix` and NixOS already filter. Version `v0.22.5` was the latest GitHub release audited on 2026-10-22.
- [ ] Track upstream fixes for `voxtype v1.1.1`: `pkgs/voxtype/Cargo.lock` overrides upstream's lock to update `bytes`, `crossbeam-epoch`, `openssl`, `openssl-sys`, `quinn-proto`, `rustls`, `rustls-webpki`, `webpki-roots` and `webpki-root-certs` (the last three trusted the compromised eMudhra intermediates, `RUSTSEC-2026-0381`–`RUSTSEC-2026-0383`; `openssl 0.10.75` carried `RUSTSEC-2026-0463` and `RUSTSEC-2026-0473`–`RUSTSEC-2026-0479`). Regenerate it on each voxtype bump and drop it once upstream ships these versions. `quick-xml 0.39.2` (`RUSTSEC-2026-0194`, `RUSTSEC-2026-0195`, fixed in `>=0.41.0`) and `libsqlite3-sys 0.30.1` (`RUSTSEC-2026-0459`, bundled SQLite, fixed in `>=0.39.0` via `rusqlite >=0.41`) need semver-breaking upstream updates. `v1.2.0` (2026-11-10) keeps all of these versions. Audited on 2026-11-11.
- [ ] Return `lox/notion-cli` to a release tag once one follows `v0.6.0`: the flake pins main at `f237f53e` (2026-11-01, unreleased) because it updates the dependencies behind 18 of the release's 21 Go advisories. Module-mode govulncheck still reports `golang.org/x/net` (`GO-2026-6860`, `GO-2026-6866`, fixed in `>=0.62.0`) and `github.com/mark3labs/mcp-go v0.43.2` (`GO-2026-6911`, a redirect can forward the Notion token; no fixed version). The pin also carries unreleased features (image upload, `--profile` accounts). Audited on 2026-11-11.
- [x] Refresh `nixpkgs` once it carries Go `1.26.4` or newer; the locked Go toolchain is now `1.26.7`, and the 2026-09-09 module-mode audit reports no standard-library advisories.
- [ ] Scope the homelab CA to TLS on macOS: `bin/setup-homelab-ca.sh` adds it with no `-p ssl`, so the System keychain trusts it for every policy. The fix needs `sudo` to test: re-add with `-p ssl`, and make the idempotence check read `security dump-trust-settings -d`, because `verify-cert -p ssl` already passes under the all-policy trust.
- [ ] Bump `oracle` to `0.23.0` once the 7-day cooldown ends on 2026-11-12T23:44Z, and consider `voxtype v1.2.1` (a feature release with a model-config migration; it keeps the advisories tracked above).
- Accepted on 2026-11-11, recorded so later audits do not reopen them without new facts:
  - `home/.omp/agent/config.yml` keeps `approvalMode: yolo`. Shell commands run with no prompt, so a prompt injection runs with the user's keys; the `delete` and `move` prompts do not cover `rm` or `mv` through bash.
  - `projects/omp-phone` keeps a 30-day session with no idle timeout. With `yolo`, a signed-in phone can run commands for that long without the security key.
  - `pkgs/berkley-mono` keeps its passphrase beside the encrypted blob; the encryption only hides the font from casual browsing.
  - `nixos/hosts/jmws.nix` keeps `@wheel` in Nix `trusted-users`, which lets `jmq` reach root through the Nix daemon without the sudo password.
  - `bin/bootstrap-rust.sh` installs rustup's `stable` channel unpinned, and the tailnet name, device addresses and login in host modules are public.

## Emacs cleanup
- [ ] Inventory any remaining `.doom.d/` assumptions and delete/archive stale Doom config if it is truly unused.
- [ ] Document handcrafted Emacs parity gaps only if they still matter in practice.
- [ ] Make the launchd/systemd Emacs service and `emacs-handcrafted-client` use one server socket. The service serves `server`, the client connects to `handcrafted`, so the first `$EDITOR` call after login cold-starts a second daemon (8-20 s measured under load).

## Pi / review tooling
- [ ] Decide whether to add opinionated pi style defaults beyond the current agent config.
- [ ] Consider a small smoke-test path for the `/review` extension beyond the current unit tests.
- [ ] Get deeply familiar with ast-grep and dylint, then integrate deterministic AST-aware linting and rewrites into daily workflows.

