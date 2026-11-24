set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

nix_eval_opts := if `nix --version 2>/dev/null || true` =~ "Determinate Nix" { "--option eval-cores 0" } else { "" }

default:
    @just --list

fmt *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v nixfmt >/dev/null 2>&1; then
        has_path_arg=0
        after_double_dash=0
        for arg in "$@"; do
            if [ "$after_double_dash" -eq 1 ]; then
                has_path_arg=1
                break
            fi
            case "$arg" in
            --) after_double_dash=1 ;;
            -*) ;;
            *)
                has_path_arg=1
                break
                ;;
            esac
        done
        if [ "$has_path_arg" -eq 1 ]; then
            exec nixfmt "$@"
        fi
        files=()
        while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z -- '*.nix')
        if [ "${#files[@]}" -gt 0 ]; then
            exec nixfmt "$@" "${files[@]}"
        fi
    else
        if [ "$#" -gt 0 ]; then
            exec nix fmt -- "$@"
        else
            exec nix fmt
        fi
    fi

eval:
    nix flake check --no-build {{ nix_eval_opts }}

check:
    nix flake check --keep-going {{ nix_eval_opts }}

test:
    tests/run.sh

test-fast:
    tests/run.sh --fast

check-fast:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v nixfmt >/dev/null 2>&1; then
        nix_files=()
        while IFS= read -r -d '' f; do nix_files+=("$f"); done < <(git ls-files -z -- '*.nix')
        if [ "${#nix_files[@]}" -gt 0 ]; then
            nixfmt --check "${nix_files[@]}"
        fi
    else
        nix fmt -- --check
    fi
    sh_files=()
    while IFS= read -r -d '' f; do sh_files+=("$f"); done < <(git ls-files -z -- '.githooks/pre-push' 'bin/*.sh' 'bin/emacs-handcrafted*' 'bin/linear' 'tests/*.sh')
    if [ "${#sh_files[@]}" -gt 0 ]; then
        shellcheck "${sh_files[@]}"
        shfmt -d "${sh_files[@]}"
    fi
    tests/run.sh --fast

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

update-input input:
    nix flake update "$1"

switch *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$(uname -s)" == "Linux" && -r /etc/os-release ]] && grep -Eq '^ID="?nixos"?$' /etc/os-release; then
        host_name="$(hostname -s 2>/dev/null || hostname)"
        exec sudo nixos-rebuild switch --flake ".#${host_name}" "$@"
    fi
    exec bin/hm-switch.sh "$@"

rust-update:
    bin/bootstrap-rust.sh --update stable
