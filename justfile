set shell := ["bash", "-euo", "pipefail", "-c"]

update:
    nix flake update
