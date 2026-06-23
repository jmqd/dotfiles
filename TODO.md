# TODO

## Current priorities
- [ ] Add lightweight repo quality checks and a canonical `nix flake check` path.
- [ ] Audit the remaining `bin/` scripts and decide which should be exposed in Home Manager PATH, kept repo-local, or archived.
- [ ] Tighten bootstrap docs for macOS, Linux, NixOS, and the optional private-data follow-on flow.

## Private/bootstrap follow-ups
- [ ] Decide whether `bin/link-private-data.sh` should stay as a script or move into a private Home Manager layer.
- [ ] Keep `~/.env` provisioning explicit and documented.

## Security follow-ups
- [x] Ignore or relocate generated local auth/session files such as `home/.pi/agent/auth.json` so they cannot be accidentally committed if populated.
- [x] Make `bin/lint-secrets.sh` respect ignored local cache/build paths such as `emacs/var/` and add explicit gitleaks allowlists for known vendored sample-token false positives.
- [ ] Add a periodic git-history secret scan target and document the current historical false positives from vendored `.oh-my-zsh/plugins/dotenv/README.md` examples.
- [ ] Harden NixOS SSH settings explicitly in `nixos/hosts/jmws.nix` (`PasswordAuthentication`, `KbdInteractiveAuthentication`, `PermitRootLogin`, and firewall/Tailscale scoping).
- [ ] Replace the private-data `.git-credentials` symlink with an OS-backed credential helper, encrypted provisioning, or a documented rotation policy.
- [ ] Package Oracle through fixed-output Nix/npm dependencies instead of executing `npx -y @steipete/oracle@...` at runtime.
- [ ] Review the macOS bootstrap `curl | sh` Determinate Nix installer path and add checksum/signature verification or a documented manual verification option.
- [ ] Update `pkgs/flow` Rust dependencies to remove the cargo-audit yanked-crate warning for `fastrand 2.4.0` via `tempfile`.

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
