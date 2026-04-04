#!/usr/bin/env bash
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || die "run setup-git-hooks from inside a git checkout"
[ -f "$repo_root/.githooks/pre-push" ] || die "missing hook file: $repo_root/.githooks/pre-push"

chmod +x "$repo_root/.githooks/pre-push"
if [ -f "$repo_root/bin/lint-secrets.sh" ]; then
	chmod +x "$repo_root/bin/lint-secrets.sh"
fi

git -C "$repo_root" config core.hooksPath .githooks

echo "Configured git hooks path: .githooks"
echo "pre-push hook enabled for $repo_root"
