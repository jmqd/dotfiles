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
- [ ] Track upstream fixes for `voxtype v1.1.0`: cargo-audit reports `bytes 1.11.0` (`RUSTSEC-2026-0007`, fixed in `>=1.11.1`), `crossbeam-epoch 0.9.18` (`RUSTSEC-2026-0204`, fixed in `>=0.9.20`), `quick-xml 0.39.2` (`RUSTSEC-2026-0194`, `RUSTSEC-2026-0195`, fixed in `>=0.41.0`), `quinn-proto 0.11.14` (`RUSTSEC-2026-0185`, fixed in `>=0.11.15`), `rustls 0.23.36` (`RUSTSEC-2026-0285`, fixed in `>=0.23.45`), and `rustls-webpki 0.103.8` (`RUSTSEC-2026-0049`, fixed in `>=0.103.10`; `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099`, `RUSTSEC-2026-0104`, fixed in `>=0.103.13`). Version `v1.1.0` was the latest GitHub release audited on 2026-10-01.
- [ ] Track upstream fixes for `openai/codex rust-v0.163.0`: cargo-audit on `codex-rs/Cargo.lock` reports `webpki-roots 1.0.5` and `webpki-root-certs 1.0.5` (`RUSTSEC-2026-0381`, `RUSTSEC-2026-0383`, trust the compromised eMudhra intermediates; fixed in `>=1.0.10`), `rustls-webpki 0.103.15` (`RUSTSEC-2026-0382`, fixed in `>=0.103.16`), `rustls 0.23.45` (`RUSTSEC-2026-0346`–`RUSTSEC-2026-0349`, fixed in `>=0.23.46`), `zip 2.4.2` (`RUSTSEC-2026-0367`–`RUSTSEC-2026-0369`), `hickory-proto 0.25.2` (`RUSTSEC-2026-0118`, with no fixed upgrade currently reported; `RUSTSEC-2026-0119`, fixed in `>=0.26.1`) and `quick-xml 0.39.4` (`RUSTSEC-2026-0194`, `RUSTSEC-2026-0195`, fixed in `>=0.41.0`). The pin is a prebuilt binary, so only an upstream release fixes these. Version `rust-v0.163.0` was the latest GitHub release audited on 2026-10-22.
- [ ] Track upstream fixes for `lox/notion-cli v0.6.0`: module-mode govulncheck with locked Go `1.26.9` reports 19 findings in `golang.org/x/text v0.33.0` (`GO-2026-5970`, fixed in `>=0.39.0`; `GO-2026-6629`, fixed in `>=0.41.0`), `golang.org/x/net v0.49.0` (`GO-2026-4918`, fixed in `>=0.53.0`; `GO-2026-5025`–`GO-2026-5030`, fixed in `>=0.55.0`; `GO-2026-5942`, fixed in `>=0.56.0`; `GO-2026-6603`, `GO-2026-6610`–`GO-2026-6612`, `GO-2026-6617`, fixed in `>=0.60.0`), `golang.org/x/sys v0.40.0` (`GO-2026-5024`, fixed in `>=0.44.0`), `github.com/yuin/goldmark v1.7.8` (`GO-2026-5320`, fixed in `>=1.7.17`), and `github.com/buger/jsonparser v1.1.1` (`GO-2026-4514`, fixed in `>=1.1.2`). The standard library needs Go `1.26.10` for `GO-2026-6809` (eMudhra intermediates); refresh `nixpkgs` once it ships. Version `v0.6.0` was the latest GitHub release audited on 2026-10-22.
- [x] Refresh `nixpkgs` once it carries Go `1.26.4` or newer; the locked Go toolchain is now `1.26.7`, and the 2026-09-09 module-mode audit reports no standard-library advisories.

## Emacs cleanup
- [ ] Inventory any remaining `.doom.d/` assumptions and delete/archive stale Doom config if it is truly unused.
- [ ] Document handcrafted Emacs parity gaps only if they still matter in practice.

## Pi / review tooling
- [ ] Decide whether to add opinionated pi style defaults beyond the current agent config.
- [ ] Consider a small smoke-test path for the `/review` extension beyond the current unit tests.
- [ ] Get deeply familiar with ast-grep and dylint, then integrate deterministic AST-aware linting and rewrites into daily workflows.

