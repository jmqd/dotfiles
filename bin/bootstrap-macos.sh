#!/usr/bin/env bash
set -euo pipefail

repo_slug="${DOTFILES_REPO:-jmqd/dotfiles}"
checkout_dir="${DOTFILES_CHECKOUT_DIR:-$HOME/src/dotfiles}"
backup_ext="${HM_BACKUP_EXT:-hm-backup}"
current_user="${DOTFILES_HOME_USER:-${USER:-$(id -un)}}"
os_name="$(uname -s)"
arch_name="$(uname -m)"
readonly repo_slug checkout_dir backup_ext current_user os_name arch_name

has_nix() {
  command -v nix >/dev/null 2>&1
}

require_macos() {
  if [[ "$os_name" != "Darwin" ]]; then
    echo "bootstrap-macos.sh only supports macOS." >&2
    exit 1
  fi
}

detect_flake_ref() {
  case "$arch_name" in
    arm64)
      printf 'github:%s#%s@macos-aarch64\n' "$repo_slug" "$current_user"
      ;;
    x86_64)
      printf 'github:%s#%s@macos-x86_64\n' "$repo_slug" "$current_user"
      ;;
    *)
      echo "Unsupported macOS architecture: $arch_name" >&2
      exit 1
      ;;
  esac
}

install_determinate_nix() {
  if has_nix; then
    return
  fi

  echo "Installing Determinate Nix..."
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix |
    sh -s -- install --determinate
}

load_nix_profile() {
  if has_nix; then
    return
  fi

  local profile_script="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

  if [[ -r "$profile_script" ]]; then
    # shellcheck source=/dev/null
    . "$profile_script"
  fi

  if ! has_nix; then
    echo "nix is still unavailable after installation." >&2
    exit 1
  fi
}

ensure_nix() {
  install_determinate_nix
  load_nix_profile
}

apply_home_manager() {
  local flake_ref="$1"

  echo "Applying Home Manager from ${flake_ref}..."
  nix run github:nix-community/home-manager -- switch --flake "$flake_ref" -b "$backup_ext"
}

apply_config() {
  local flake_ref="$1"

  apply_home_manager "$flake_ref"
}

clone_repo() {
  if [[ -d "$checkout_dir/.git" ]]; then
    echo "Dotfiles repo already exists at $checkout_dir; skipping clone."
    return
  fi

  echo "Cloning dotfiles repo to $checkout_dir..."
  mkdir -p "$(dirname "$checkout_dir")"
  nix shell nixpkgs#git -c git clone "https://github.com/${repo_slug}.git" "$checkout_dir"
}

ensure_checkout() {
  clone_repo
}

print_next_steps() {
  cat <<EOF

Bootstrap complete.

Next steps:
1. Open a new shell so Home Manager's shell changes are active.
2. If you want the repo checked out locally, it is at:
   $checkout_dir
EOF
}

main() {
  require_macos

  local flake_ref
  flake_ref="$(detect_flake_ref)"

  ensure_nix
  apply_config "$flake_ref"
  ensure_checkout
  print_next_steps
}

main "$@"
