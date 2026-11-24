#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fast=0

usage() {
	cat <<EOF
usage: $(basename "$0") [--fast]

Run local repository test suites in parallel (shell tests under tests/*.sh
and Node.js extension tests when node is available on PATH).

options:
  --fast      skip tests/clean-stale.sh for quick local feedback
  -h, --help  show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fast) fast=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
	shift
done

now_sec() {
	if [ -n "${EPOCHREALTIME:-}" ]; then
		printf '%s\n' "$EPOCHREALTIME"
	else
		date +%s
	fi
}

elapsed_fmt() {
	awk -v t0="$1" -v t1="$2" 'BEGIN { printf "%.2fs", t1 - t0 }'
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

names=()
pids=()
skipped=()
idx=0

launch_test() {
	local name="$1"
	shift
	local i="$idx"
	idx=$((idx + 1))
	names+=("$name")
	(
		t0="$(now_sec)"
		rc=0
		"$@" >"$tmp_dir/$i.out" 2>&1 || rc=$?
		t1="$(now_sec)"
		printf '%d %s\n' "$rc" "$(elapsed_fmt "$t0" "$t1")" >"$tmp_dir/$i.meta"
	) &
	pids+=($!)
}

suite_start="$(now_sec)"

for script in tests/*.sh; do
	[ -f "$script" ] || continue
	case "$script" in
	tests/run.sh) continue ;;
	tests/clean-stale.sh)
		if [ "$fast" -eq 1 ]; then
			skipped+=("$script (skipped by --fast)")
			continue
		fi
		;;
	esac
	launch_test "$script" bash "$script"
done

node_tests=(
	"home/.pi/agent/extensions/review-orchestrator/core.test.ts"
	"projects/omp-phone/extension/index.test.ts"
)
if command -v node >/dev/null 2>&1; then
	for test_file in "${node_tests[@]}"; do
		[ -f "$test_file" ] || continue
		launch_test "$test_file" node --test "$test_file"
	done
else
	for test_file in "${node_tests[@]}"; do
		[ -f "$test_file" ] || continue
		skipped+=("$test_file (node not on PATH)")
	done
fi

passed=0
failed=0
for i in "${!pids[@]}"; do
	wait "${pids[$i]}" || true
	rc=1
	dur="?"
	if [ -f "$tmp_dir/$i.meta" ]; then
		read -r rc dur <"$tmp_dir/$i.meta"
	fi
	if [ "$rc" -eq 0 ]; then
		printf 'PASS  %6s  %s\n' "$dur" "${names[$i]}"
		passed=$((passed + 1))
	else
		printf 'FAIL  %6s  %s (exit %d)\n' "$dur" "${names[$i]}" "$rc"
		if [ -s "$tmp_dir/$i.out" ]; then
			sed 's/^/  | /' "$tmp_dir/$i.out"
		fi
		failed=$((failed + 1))
	fi
done

for entry in ${skipped[@]+"${skipped[@]}"}; do
	printf 'SKIP  %6s  %s\n' "-" "$entry"
done

suite_dur="$(elapsed_fmt "$suite_start" "$(now_sec)")"
printf '\n%d passed, %d failed, %d skipped in %s\n' \
	"$passed" "$failed" "${#skipped[@]}" "$suite_dur"

if [ "$failed" -ne 0 ]; then
	exit 1
fi
