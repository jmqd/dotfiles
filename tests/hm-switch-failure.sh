#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

uname() {
	case "${1:-}" in
	-s)
		printf '%s\n' "${test_os:-Darwin}"
		;;
	-m)
		printf '%s\n' "${test_arch:-x86_64}"
		;;
	*)
		return 64
		;;
	esac
}

env() {
	while [[ $# -gt 0 && $1 == *=* ]]; do
		export "${1?}"
		shift
	done

	"$@"
}

nix() {
	printf '%s\n' 'simulated home-manager switch failure' >&2
	return 73
}

export -f env nix uname

set +e
output="$(bash "$repo_root/bin/hm-switch.sh" 2>&1)"
status=$?
set -e

if [[ $status -ne 73 ]]; then
	printf '%s\n' "$output" >&2
	printf 'expected hm-switch.sh to return nix failure status 73, got %d\n' "$status" >&2
	exit 1
fi

# Invalid automatic profile selection must stop before Home Manager runs.
export test_os=Linux
for test_arch in x86_64 aarch64; do
	export test_arch
	set +e
	output="$(HM_PROFILE=invalid bash "$repo_root/bin/hm-switch.sh" 2>&1)"
	status=$?
	set -e
	if [[ $status -ne 1 ]]; then
		printf '%s\n' "$output" >&2
		printf 'expected invalid profile to fail before nix (status 1), got %d\n' "$status" >&2
		exit 1
	fi
done
