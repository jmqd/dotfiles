#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component_add_seen=0
default_seen=0
toolchain_install_seen=0

rustup() {
	case "$*" in
	'toolchain install stable --profile minimal')
		toolchain_install_seen=1
		;;
	'default stable')
		default_seen=1
		;;
	'component list --toolchain stable --installed')
		printf '%s\n' \
			'cargo-x86_64-apple-darwin' \
			'rust-std-x86_64-apple-darwin' \
			'rustc-x86_64-apple-darwin'
		;;
	'component add --toolchain stable rustfmt clippy rust-analyzer rust-src')
		component_add_seen=1
		;;
	*)
		printf 'unexpected rustup request: %s\n' "$*" >&2
		return 64
		;;
	esac
}
export -f rustup

export RUSTUP_BIN=rustup
enable -n mapfile

# shellcheck source=/dev/null
source "$repo_root/bin/bootstrap-rust.sh" stable

if [[ $toolchain_install_seen -ne 1 || $default_seen -ne 1 ]]; then
	printf '%s\n' 'bootstrap did not update and select the requested toolchain' >&2
	exit 1
fi

if [[ $component_add_seen -ne 1 ]]; then
	printf '%s\n' 'bootstrap did not request all missing default components' >&2
	exit 1
fi
