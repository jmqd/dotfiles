#!/usr/bin/env bash
set -euo pipefail

repo_slug="${DOTFILES_REPO:-jmqd/dotfiles}"
checkout_dir="${DOTFILES_CHECKOUT_DIR:-$HOME/src/dotfiles}"
backup_ext="${HM_BACKUP_EXT:-hm-backup}"
current_user="${DOTFILES_HOME_USER:-${USER:-$(id -un)}}"
determinate_installer_url="${DETERMINATE_NIX_INSTALLER_URL:-https://install.determinate.systems/nix}"
os_name="$(uname -s)"
arch_name="$(uname -m)"
readonly repo_slug checkout_dir backup_ext current_user determinate_installer_url os_name arch_name

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
		printf '%s#macos-aarch64\n' "$checkout_dir"
		;;
	x86_64)
		printf '%s#macos-x86_64\n' "$checkout_dir"
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

	local installer_path installer_hash
	installer_path="$(mktemp "${TMPDIR:-/tmp}/determinate-nix-installer.XXXXXX")"

	echo "Installing Determinate Nix..."
	curl --proto '=https' --tlsv1.2 -sSf -L "$determinate_installer_url" -o "$installer_path"
	installer_hash="$(shasum -a 256 "$installer_path" | cut -d ' ' -f 1)"

	cat <<EOF
Downloaded Determinate Nix installer:
  URL: $determinate_installer_url
  File: $installer_path
  SHA-256: $installer_hash
EOF

	if [[ "${DOTFILES_DETERMINATE_NIX_VERIFY_ONLY:-0}" == "1" ]]; then
		cat <<EOF
DOTFILES_DETERMINATE_NIX_VERIFY_ONLY=1 is set, so the installer was not run.
Inspect the file above, verify the hash out of band if desired, then run:
  sh "$installer_path" install --determinate
EOF
		exit 0
	fi

	sh "$installer_path" install --determinate
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

	echo "Applying Home Manager from ${flake_ref} for user ${current_user}..."
	HM_USER="$current_user" \
		HM_BACKUP_EXT="$backup_ext" \
		HM_REFRESH=1 \
		"$checkout_dir/bin/hm-switch.sh" "$flake_ref"
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
2. The repo is checked out locally at:
   $checkout_dir
EOF
}

main() {
	require_macos

	ensure_nix
	ensure_checkout

	local flake_ref
	flake_ref="$(detect_flake_ref)"

	apply_config "$flake_ref"
	print_next_steps
}

main "$@"
