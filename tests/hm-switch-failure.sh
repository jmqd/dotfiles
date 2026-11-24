#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hm-switch-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
args_log="$tmp_dir/args.log"
cat >"$tmp_dir/bin/home-manager" <<'EOF'
#!/usr/bin/env bash
printf 'HM_BOOTSTRAP_USER=%s\n' "${HM_BOOTSTRAP_USER:-}" >"$HM_TEST_ARGS_LOG"
printf '%s\n' "$@" >>"$HM_TEST_ARGS_LOG"
printf '%s\n' 'simulated direct home-manager switch failure' >&2
exit 73
EOF
chmod +x "$tmp_dir/bin/home-manager"

uname() {
	case "${1:-}" in
	-s)
		printf '%s\n' "${test_os:-Darwin}"
		;;
	-m)
		printf '%s\n' "${test_arch:-arm64}"
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
	if [[ "${1:-}" == "--version" ]]; then
		printf '%s\n' "${test_nix_version:-nix (Nix) 2.35.6}"
		return 0
	fi
	printf '%s\n' 'simulated home-manager switch failure' >&2
	return 73
}

export -f env nix uname

# 1. nix run fallback (HM_REFRESH=1) propagates failure status 73.
set +e
output="$(HM_REFRESH=1 bash "$repo_root/bin/hm-switch.sh" 2>&1)"
status=$?
set -e

if [[ $status -ne 73 ]]; then
	printf '%s\n' "$output" >&2
	printf 'expected hm-switch.sh (nix run) to return status 73, got %d\n' "$status" >&2
	exit 1
fi

# 2. Direct home-manager on PATH as jmq uses pure macos-aarch64 without --impure,
#    and skips --option eval-cores 0 on upstream Nix.
: >"$args_log"
set +e
output="$(
	PATH="$tmp_dir/bin:$PATH" \
		HM_TEST_ARGS_LOG="$args_log" \
		HOME="/Users/jmq" \
		USER="jmq" \
		HM_USER="" \
		HM_BOOTSTRAP_USER="" \
		test_nix_version="nix (Nix) 2.35.6" \
		bash "$repo_root/bin/hm-switch.sh" 2>&1
)"
status=$?
set -e

if [[ $status -ne 73 ]]; then
	printf '%s\n' "$output" >&2
	printf 'expected direct home-manager failure status 73, got %d\n' "$status" >&2
	exit 1
fi
if ! grep -Fxq "${repo_root}#macos-aarch64" "$args_log"; then
	cat "$args_log" >&2
	printf 'expected pure macos-aarch64 flake ref\n' >&2
	exit 1
fi
if grep -Fxq -- "--impure" "$args_log"; then
	cat "$args_log" >&2
	printf 'did not expect --impure for pure macos-aarch64 switch as jmq\n' >&2
	exit 1
fi
if grep -Fxq "eval-cores" "$args_log"; then
	cat "$args_log" >&2
	printf 'did not expect eval-cores on upstream Nix\n' >&2
	exit 1
fi

# 3. Non-jmq Darwin user selects macos-aarch64-bootstrap with --impure and
#    passes --option eval-cores 0 on Determinate Nix.
: >"$args_log"
set +e
output="$(
	PATH="$tmp_dir/bin:$PATH" \
		HM_TEST_ARGS_LOG="$args_log" \
		HOME="/Users/alice" \
		USER="alice" \
		HM_USER="alice" \
		HM_BOOTSTRAP_USER="" \
		test_nix_version="nix (Determinate Nix 3.13.2) 2.32.4" \
		bash "$repo_root/bin/hm-switch.sh" 2>&1
)"
status=$?
set -e

if [[ $status -ne 73 ]]; then
	printf '%s\n' "$output" >&2
	printf 'expected bootstrap failure status 73, got %d\n' "$status" >&2
	exit 1
fi
if ! grep -Fxq "${repo_root}#macos-aarch64-bootstrap" "$args_log" ||
	! grep -Fxq -- "--impure" "$args_log" ||
	! grep -Fxq "HM_BOOTSTRAP_USER=alice" "$args_log" ||
	! grep -Fxq "eval-cores" "$args_log"; then
	cat "$args_log" >&2
	printf 'expected bootstrap target, --impure, HM_BOOTSTRAP_USER=alice, and eval-cores\n' >&2
	exit 1
fi

# 4. Explicit HM_BOOTSTRAP_USER with work-macos-aarch64 rewrites to -bootstrap.
: >"$args_log"
set +e
output="$(
	PATH="$tmp_dir/bin:$PATH" \
		HM_TEST_ARGS_LOG="$args_log" \
		HOME="/Users/jmq" \
		USER="jmq" \
		HM_USER="" \
		HM_BOOTSTRAP_USER="bob" \
		bash "$repo_root/bin/hm-switch.sh" "${repo_root}#work-macos-aarch64" 2>&1
)"
status=$?
set -e

if [[ $status -ne 73 ]] ||
	! grep -Fxq "${repo_root}#work-macos-aarch64-bootstrap" "$args_log" ||
	! grep -Fxq -- "--impure" "$args_log" ||
	! grep -Fxq "HM_BOOTSTRAP_USER=bob" "$args_log"; then
	printf '%s\n' "$output" >&2
	cat "$args_log" >&2
	printf 'expected work-macos-aarch64-bootstrap with --impure and HM_BOOTSTRAP_USER=bob\n' >&2
	exit 1
fi

# 5. Invalid automatic profile selection must stop before Home Manager runs.
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
