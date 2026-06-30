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
- [ ] Track upstream fixes for `googleworkspace/cli v0.22.5`: cargo-audit still reports `quinn-proto 0.11.14` (`RUSTSEC-2026-0185`, fixed in `>=0.11.15`) and `rustls-webpki 0.103.10` (`RUSTSEC-2026-0104`, `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099`, fixed in `>=0.103.13` for the CRL panic and `>=0.103.12` for the name-constraint issues). No newer GitHub release was available on 2026-06-24.
- [ ] Track upstream fixes for `openai/codex rust-v0.142.0`: cargo-audit reports `hickory-proto 0.25.2` (`RUSTSEC-2026-0118`, `RUSTSEC-2026-0119`, fixed by the 0.26.x line) and `quinn-proto 0.11.14` (`RUSTSEC-2026-0185`, fixed in `>=0.11.15`) in `codex-rs/Cargo.lock`, plus `tar 0.4.44` (`RUSTSEC-2026-0067`, `RUSTSEC-2026-0068`, fixed in `>=0.4.45`) in `tools/argument-comment-lint/Cargo.lock`. No newer Codex release was available on 2026-06-24.
- [ ] Track upstream fixes for `lox/notion-cli v0.6.0`: govulncheck reports reachable `golang.org/x/net/html v0.49.0` advisories `GO-2026-5025`, `GO-2026-5027`, `GO-2026-5028`, `GO-2026-5029`, and `GO-2026-5030`, fixed in `golang.org/x/net v0.55.0`. No newer GitHub release was available on 2026-06-24.
- [x] Refresh `nixpkgs` once it carries Go `1.26.4` or newer; current lock builds Go binaries with `go1.26.4`, and binary-mode govulncheck no longer reports the `GO-2026-5037`/`GO-2026-5039` standard-library advisories.

## Emacs cleanup
- [ ] Inventory any remaining `.doom.d/` assumptions and delete/archive stale Doom config if it is truly unused.
- [ ] Periodically check whether nixpkgs applies the Tree-sitter 0.26 fix to `emacs-macport`, then remove the local override in `home/emacs.nix`.
- [ ] Document handcrafted Emacs parity gaps only if they still matter in practice.

## Pi / review tooling
- [ ] Decide whether to add opinionated pi style defaults beyond the current agent config.
- [ ] Consider a small smoke-test path for the `/review` extension beyond the current unit tests.
- [ ] Get deeply familiar with ast-grep and dylint, then integrate deterministic AST-aware linting and rewrites into daily workflows.

## Hive follow-ups
- [ ] Decide whether hive should move from live-repo worktrees to a local bare mirror.
- [ ] Evaluate stronger sandboxing defaults (`--hardened`, non-root user, read-only rootfs, dedicated store).
- [ ] Add a small Docker/OrbStack smoke-test path for hive.
