#!/usr/bin/env bash
set -euo pipefail

rustup_bin="${RUSTUP_BIN:-rustup}"
toolchain="${1:-stable}"
shift || true

profile="${RUSTUP_PROFILE:-minimal}"
if [[ $# -gt 0 ]]; then
	components=("$@")
else
	components=(rustfmt clippy rust-analyzer rust-src)
fi

if ! command -v "$rustup_bin" >/dev/null 2>&1; then
	echo "rustup not found: $rustup_bin" >&2
	exit 1
fi

missing_components() {
	local installed="$1"
	local component
	local installed_component
	local found

	for component in "${components[@]}"; do
		found=0
		while IFS= read -r installed_component; do
			case "$installed_component" in
			"$component" | "$component"-*)
				found=1
				break
				;;
			esac
		done <<<"$installed"
		if [[ "$found" -eq 0 ]]; then
			printf '%s\n' "$component"
		fi
	done
}

target_toolchain="$toolchain"
echo "Installing or updating rustup toolchain: $target_toolchain (profile: $profile)"
"$rustup_bin" toolchain install "$target_toolchain" --profile "$profile"
"$rustup_bin" default "$target_toolchain"

if [[ ${#components[@]} -gt 0 ]]; then
	installed="$("$rustup_bin" component list --toolchain "$target_toolchain" --installed)"
	missing=()
	while IFS= read -r missing_component; do
		missing+=("$missing_component")
	done < <(missing_components "$installed")
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Installing missing rustup components on ${target_toolchain}: ${missing[*]}"
		"$rustup_bin" component add --toolchain "$target_toolchain" "${missing[@]}"
	else
		echo "Rust components already installed on ${target_toolchain}: ${components[*]}"
	fi
fi

echo "Rust bootstrap complete."
