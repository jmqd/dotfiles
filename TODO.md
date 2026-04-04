# TODO

## Current priorities
- [ ] Add lightweight repo quality checks and a canonical `nix flake check` path.
- [ ] Audit the remaining `bin/` scripts and decide which should be exposed in Home Manager PATH, kept repo-local, or archived.
- [ ] Tighten bootstrap docs for macOS, Linux, NixOS, and the optional private-data follow-on flow.

## Private/bootstrap follow-ups
- [ ] Decide whether `bin/link-private-data.sh` should stay as a script or move into a private Home Manager layer.
- [ ] Keep `~/.env` provisioning explicit and documented.
- [ ] Revisit whether `~/.cloudhome.json` is still needed.

## Emacs cleanup
- [ ] Inventory any remaining `.doom.d/` assumptions and delete/archive stale Doom config if it is truly unused.
- [ ] Document handcrafted Emacs parity gaps only if they still matter in practice.

## Pi / review tooling
- [ ] Decide whether to add opinionated pi style defaults beyond the current agent config.
- [ ] Consider a small smoke-test path for the `/review` extension beyond the current unit tests.

## Hive follow-ups
- [ ] Decide whether hive should move from live-repo worktrees to a local bare mirror.
- [ ] Evaluate stronger sandboxing defaults (`--hardened`, non-root user, read-only rootfs, dedicated store).
- [ ] Add a small Docker/OrbStack smoke-test path for hive.
