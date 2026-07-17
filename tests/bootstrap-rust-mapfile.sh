#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component_add_seen=0

rustup() {
	case "$*" in
	'show active-toolchain')
		printf '%s\n' 'stable-x86_64-apple-darwin (default)'
		;;
	'component list --toolchain stable-x86_64-apple-darwin --installed')
		printf '%s\n' \
			'cargo-x86_64-apple-darwin' \
			'rust-std-x86_64-apple-darwin' \
			'rustc-x86_64-apple-darwin'
		;;
	'component add --toolchain stable-x86_64-apple-darwin rustfmt clippy rust-analyzer rust-src')
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

if [[ $component_add_seen -ne 1 ]]; then
	printf '%s\n' 'bootstrap did not request all missing default components' >&2
	exit 1
fi
