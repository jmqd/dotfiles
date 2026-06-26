# Legacy alias: the flake now packages the pinned oh-my-pi binary from
# `pkgs/omp`, but keep this path resolving to the same derivation for anyone
# looking under the old location.
import ../omp/default.nix
