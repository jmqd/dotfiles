#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_ext="${HM_BACKUP_EXT:-hm-backup}"
current_user="${HM_USER:-${USER:-$(id -un)}}"
refresh_home_manager="${HM_REFRESH:-0}"
os_name="$(uname -s)"
readonly repo_root backup_ext current_user refresh_home_manager os_name

detect_flake_ref() {
  case "${os_name}:$(uname -m)" in
    Darwin:arm64)
      printf '%s\n' "${repo_root}#macos-aarch64"
      ;;
    Darwin:x86_64)
      printf '%s\n' "${repo_root}#macos-x86_64"
      ;;
    Linux:aarch64)
      printf '%s\n' "${repo_root}#linux-aarch64"
      ;;
    Linux:x86_64)
      printf '%s\n' "${repo_root}#linux-x86_64"
      ;;
    *)
      cat >&2 <<'EOF'
Unable to infer a Home Manager flake target for this machine.
Pass one explicitly, for example:
  bin/hm-switch.sh ~/src/dotfiles#macos-aarch64
EOF
      exit 1
      ;;
  esac
}

home_manager_hit_app_management_error() {
  local log_file="$1"
  grep -Fq "permission denied when trying to update apps" "$log_file" \
    || grep -Fq "home-manager requires permission to update your apps" "$log_file"
}

open_app_management_settings() {
  if [[ "$os_name" != "Darwin" ]]; then
    return
  fi

  open -a "System Settings" >/dev/null 2>&1 || true
}

prompt_for_app_management_permission() {
  local terminal_app="${TERM_PROGRAM:-your terminal emulator}"

  cat >&2 <<EOF

Home Manager needs macOS App Management permission to update ~/Applications/Home Manager Apps.
Grant permission to ${terminal_app} in:
  System Settings > Privacy & Security > App Management

I'll open System Settings now. After granting permission, return here and press Enter to retry once.
EOF

  open_app_management_settings

  if [[ -t 0 ]]; then
    read -r -p "Press Enter to retry Home Manager..."
  else
    echo >&2 "No interactive tty detected; retrying Home Manager once immediately."
  fi
}

run_home_manager_switch() {
  local -a cmd=("$@")
  local log_file
  local status
  local attempt

  log_file="$(mktemp "${TMPDIR:-/tmp}/hm-switch.XXXXXX.log")"

  for attempt in 1 2; do
    : > "$log_file"

    if "${cmd[@]}" 2>&1 | tee "$log_file"; then
      rm -f "$log_file"
      return 0
    fi
    status=$?

    if [[ "$os_name" == "Darwin" ]] && [[ $attempt -eq 1 ]] && home_manager_hit_app_management_error "$log_file"; then
      prompt_for_app_management_permission
      continue
    fi

    rm -f "$log_file"
    return "$status"
  done

  rm -f "$log_file"
  return 1
}

flake_ref=""

if [[ $# -gt 0 && ${1:0:1} != "-" ]]; then
  flake_ref="$1"
  shift
else
  flake_ref="$(detect_flake_ref)"
fi

home_manager_cmd=(nix run)

if [[ "$refresh_home_manager" == "1" ]]; then
  home_manager_cmd+=(--refresh)
fi

home_manager_cmd+=(github:nix-community/home-manager -- switch)

if [[ "$os_name" == "Darwin" ]]; then
  home_manager_cmd+=(--impure --flake "$flake_ref" -b "$backup_ext" "$@")
else
  home_manager_cmd+=(--flake "$flake_ref" -b "$backup_ext" "$@")
fi

if [[ "$os_name" == "Darwin" ]]; then
  run_home_manager_switch env HM_BOOTSTRAP_USER="$current_user" "${home_manager_cmd[@]}"
else
  run_home_manager_switch "${home_manager_cmd[@]}"
fi
