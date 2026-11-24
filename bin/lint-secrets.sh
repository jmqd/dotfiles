#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

scan_mode="dir"
log_opts=""

usage() {
	cat <<EOF
usage: $(basename "$0") [--history | --unpushed REMOTE]

Run the default worktree secret scan. --history scans all local Git refs.
--unpushed REMOTE scans only commits on local refs that REMOTE's
remote-tracking branches do not contain. Both use the repository gitleaks
config.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--history)
		scan_mode="git"
		log_opts="--all"
		shift
		;;
	--unpushed)
		# The name becomes a ref glob inside one --log-opts string.
		case "${2:-}" in
		"" | *[!A-Za-z0-9._/-]*)
			usage >&2
			exit 2
			;;
		esac
		scan_mode="git"
		log_opts="--all --not --remotes=$2"
		shift 2
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

args=("$scan_mode" --config "$repo_root/.gitleaks.toml" --redact --exit-code 1 --no-banner .)
if [ "$scan_mode" = "git" ]; then
	args+=("--log-opts=$log_opts")
fi

if command -v gitleaks >/dev/null 2>&1; then
	echo "secrets-lint: using gitleaks from PATH"
	gitleaks "${args[@]}"
	exit 0
fi

if command -v nix >/dev/null 2>&1 && [ -f "$repo_root/flake.nix" ]; then
	echo "secrets-lint: using gitleaks from nix"
	cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
	if { [ -d "$cache_dir" ] && [ -w "$cache_dir" ]; } || { [ ! -e "$cache_dir" ] && mkdir -p "$cache_dir" 2>/dev/null; }; then
		if nix shell --quiet --no-write-lock-file --inputs-from "$repo_root" nixpkgs#gitleaks -c gitleaks "${args[@]}"; then
			exit 0
		fi
	else
		tmp_cache_dir="$(mktemp -d)"
		trap 'rm -rf "$tmp_cache_dir"' EXIT
		if XDG_CACHE_HOME="$tmp_cache_dir" nix shell --quiet --no-write-lock-file --inputs-from "$repo_root" nixpkgs#gitleaks -c gitleaks "${args[@]}"; then
			exit 0
		fi
	fi

	echo "secrets-lint: nix-based gitleaks execution failed." >&2
	echo "Try entering the shell directly with: nix develop" >&2
	exit 2
fi

echo "secrets-lint: gitleaks is not available." >&2
echo "Install it with Nix: nix develop" >&2
exit 2
