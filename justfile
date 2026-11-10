set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

default:
    @just --list

fmt:
    nix fmt

check:
    nix flake check --option eval-cores 0

audit-deps:
    bin/audit-deps.sh

clean-stale *args:
    bin/clean-stale.sh "$@"

lint-secrets:
    bin/lint-secrets.sh

lint-secrets-history:
    bin/lint-secrets.sh --history

update:
    nix flake update

rust-update:
    bin/bootstrap-rust.sh --update stable
