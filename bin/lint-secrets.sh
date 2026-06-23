#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

scan_mode="dir"

usage() {
	cat <<EOF
usage: $(basename "$0") [--history]

Run the default worktree secret scan, or use --history for a full Git history
scan with the repository gitleaks config.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--history)
		scan_mode="git"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

run_gitleaks() {
	local -a args=("$scan_mode" --config "$repo_root/.gitleaks.toml" --redact --exit-code 1 --no-banner .)
	gitleaks "${args[@]}"
}

if command -v gitleaks >/dev/null 2>&1; then
	echo "secrets-lint: using gitleaks from PATH"
	run_gitleaks
	exit 0
fi

if command -v nix >/dev/null 2>&1 && [ -f "$repo_root/flake.nix" ]; then
	echo "secrets-lint: using gitleaks from nix dev shell"
	tmp_cache_dir="$(mktemp -d)"
	trap 'rm -rf "$tmp_cache_dir"' EXIT

	if XDG_CACHE_HOME="$tmp_cache_dir" nix develop --quiet --no-write-lock-file --command gitleaks "$scan_mode" --config "$repo_root/.gitleaks.toml" --redact --exit-code 1 --no-banner .; then
		exit 0
	fi

	echo "secrets-lint: nix-based gitleaks execution failed." >&2
	echo "Try entering the shell directly with: nix develop" >&2
	exit 2
fi

echo "secrets-lint: gitleaks is not available." >&2
echo "Install it with Nix: nix develop" >&2
exit 2
