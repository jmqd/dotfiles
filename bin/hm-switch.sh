#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_ext="${HM_BACKUP_EXT:-hm-backup}"
current_user="${HM_USER:-${USER:-$(id -un)}}"

detect_flake_ref() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
      printf '%s\n' "${repo_root}#${current_user}@macos-aarch64"
      ;;
    Darwin:x86_64)
      printf '%s\n' "${repo_root}#${current_user}@macos-x86_64"
      ;;
    Linux:aarch64)
      printf '%s\n' "${repo_root}#jmq@linux-aarch64"
      ;;
    Linux:x86_64)
      printf '%s\n' "${repo_root}#jmq@linux-x86_64"
      ;;
    *)
      cat >&2 <<'EOF'
Unable to infer a Home Manager flake target for this machine.
Pass one explicitly, for example:
  bin/hm-switch.sh ~/src/dotfiles#jmq@macos-aarch64
EOF
      exit 1
      ;;
  esac
}

flake_ref=""

if [[ $# -gt 0 && ${1:0:1} != "-" ]]; then
  flake_ref="$1"
  shift
else
  flake_ref="$(detect_flake_ref)"
fi

exec nix run github:nix-community/home-manager -- switch --flake "$flake_ref" -b "$backup_ext" "$@"
