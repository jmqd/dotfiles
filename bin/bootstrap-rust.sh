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

get_active_toolchain() {
	local active
	active="$($rustup_bin show active-toolchain)"
	printf '%s\n' "${active%% *}"
}

missing_components() {
	local installed
	local component
	local installed_component
	local found
	installed="$("$rustup_bin" component list --toolchain "$active_toolchain" --installed)"

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

active_toolchain=""
if "$rustup_bin" show active-toolchain >/dev/null 2>&1; then
	active_toolchain="$(get_active_toolchain)"
	echo "Rust toolchain already initialized: $active_toolchain"
else
	echo "Initializing rustup default toolchain: $toolchain (profile: $profile)"
	"$rustup_bin" toolchain install "$toolchain" --profile "$profile"
	"$rustup_bin" default "$toolchain"
	active_toolchain="$(get_active_toolchain)"
fi

if [[ ${#components[@]} -gt 0 ]]; then
	mapfile -t missing < <(missing_components)
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Installing missing rustup components on ${active_toolchain}: ${missing[*]}"
		"$rustup_bin" component add --toolchain "$active_toolchain" "${missing[@]}"
	else
		echo "Rust components already installed on ${active_toolchain}: ${components[*]}"
	fi
fi

echo "Rust bootstrap complete."
