#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component_add_seen=0
default_seen=0
toolchain_install_seen=0

rustup() {
	case "$*" in
	'show active-toolchain')
		if [[ "${RUSTUP_TEST_OVERRIDDEN:-0}" == 1 ]]; then
			printf '%s\n' '1.88.0-aarch64-apple-darwin (overridden by /tmp/rust-toolchain.toml)'
			return 0
		fi
		if [[ "${RUSTUP_TEST_EXISTING:-0}" == 1 ]]; then
			printf '%s\n' 'stable-aarch64-apple-darwin (default)'
			return 0
		fi
		return 1
		;;
	'run stable rustc --version')
		[[ "${RUSTUP_TEST_EXISTING:-0}" == 1 ]]
		;;
	'toolchain install stable --profile minimal')
		toolchain_install_seen=1
		;;
	'default stable')
		default_seen=1
		;;
	'component list --toolchain stable --installed')
		if [[ "${FAIL_COMPONENT_LIST:-0}" == 1 ]]; then
			return 42
		fi
		if [[ "${RUSTUP_TEST_EXISTING:-0}" == 1 ]]; then
			printf '%s\n' rustfmt clippy rust-analyzer rust-src
			return
		fi
		printf '%s\n' \
			'cargo-aarch64-apple-darwin' \
			'rust-std-aarch64-apple-darwin' \
			'rustc-aarch64-apple-darwin'
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

# A usable installation must not be updated or downloaded on activation.
export RUSTUP_TEST_EXISTING=1
toolchain_install_seen=0
default_seen=0
component_add_seen=0
# shellcheck source=/dev/null
source "$repo_root/bin/bootstrap-rust.sh" stable
if [[ $toolchain_install_seen -ne 0 || $default_seen -ne 0 || $component_add_seen -ne 0 ]]; then
	echo "existing toolchain unexpectedly requested an install, default switch, or update" >&2
	exit 1
fi

# A directory override must fall back to verifying the target toolchain without reinstalling.
RUSTUP_TEST_OVERRIDDEN=1 toolchain_install_seen=0 default_seen=0 component_add_seen=0
export RUSTUP_TEST_OVERRIDDEN
# shellcheck source=/dev/null
source "$repo_root/bin/bootstrap-rust.sh" stable
unset RUSTUP_TEST_OVERRIDDEN
if [[ $toolchain_install_seen -ne 0 || $default_seen -ne 1 || $component_add_seen -ne 0 ]]; then
	echo "overridden toolchain fallback behaved unexpectedly" >&2
	exit 1
fi

# Updates remain available through an explicit user command.
# shellcheck source=/dev/null
source "$repo_root/bin/bootstrap-rust.sh" --update stable
if [[ $toolchain_install_seen -ne 1 || $default_seen -ne 1 ]]; then
	echo "explicit toolchain update was skipped" >&2
	exit 1
fi

# A failed installed-component query must not report successful bootstrap.
set +e
FAIL_COMPONENT_LIST=1 bash "$repo_root/bin/bootstrap-rust.sh" stable >/dev/null 2>&1
status=$?
set -e
if [[ $status -ne 42 ]]; then
	printf 'expected component-list failure status 42, got %d\n' "$status" >&2
	exit 1
fi
