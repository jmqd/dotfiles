#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

chmod +x "$repo_root/.githooks/pre-push"
chmod +x "$repo_root/bin/lint-secrets.sh"
git -C "$repo_root" config core.hooksPath .githooks

echo "Configured git hooks path: .githooks"
echo "pre-push hook enabled for $repo_root"
