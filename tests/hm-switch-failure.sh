#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

uname() {
	case "${1:-}" in
	-s)
		printf '%s\n' Darwin
		;;
	-m)
		printf '%s\n' x86_64
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
