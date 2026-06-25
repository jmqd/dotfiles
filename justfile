set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

fmt:
    nix fmt

check:
    nix flake check

audit-deps:
    bin/audit-deps.sh

lint-secrets:
    bin/lint-secrets.sh

lint-secrets-history:
    bin/lint-secrets.sh --history

update:
    nix flake update
