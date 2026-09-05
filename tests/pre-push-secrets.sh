#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cd "$work_dir"
git init --quiet --initial-branch=main
git config user.name 'Secret Scan Test'
git config user.email 'secret-scan@example.invalid'
git config commit.gpgsign false
git config core.hooksPath /dev/null
mkdir bin
cp "$repo_root/bin/lint-secrets.sh" bin/
chmod +x bin/lint-secrets.sh
cat >.gitleaks.toml <<'EOF'
[[rules]]
id = "regression-fixture"
description = "Non-secret regression marker"
regex = '''history-scan-fixture-[0-9]+'''
EOF
printf 'safe\n' >example.txt
git add example.txt .gitleaks.toml
git commit --quiet -m 'Clean baseline'

bash "$repo_root/.githooks/pre-push" >/dev/null 2>&1

git checkout --quiet -b outgoing
printf 'history-scan-fixture-%s\n' 123456 >example.txt
git add example.txt
git commit --quiet -m 'Add fixture'
printf 'safe again\n' >example.txt
git add example.txt
git commit --quiet -m 'Remove fixture'
git checkout --quiet main

# Neither the worktree nor HEAD history contains the marker. A different
# local branch still contains it in an earlier commit that could be pushed.
bash bin/lint-secrets.sh >/dev/null 2>&1
if bash "$repo_root/.githooks/pre-push" >scan.log 2>&1; then
	printf 'pre-push accepted a secret in another local branch history\n' >&2
	exit 1
fi
printf 'PASS: pre-push rejects secrets removed from a non-HEAD branch\n'
