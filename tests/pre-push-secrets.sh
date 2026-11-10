#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
remotes_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir" "$remotes_dir"' EXIT

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

write_sh_script() {
	local path="$1" last_line="$2"
	printf '#!/bin/sh\nset -u\n\nmain() {\n\tprintf '\''ok\\n'\''\n}\n\n%s\n' "$last_line" >"$path"
}

# House-style POSIX sh (set -u, explicit failure paths) is accepted only
# with the final guard that keeps a truncated script from running.
write_sh_script bin/guarded.sh 'main "$@" || exit 1'
git add bin/guarded.sh
git commit --quiet -m 'Add guarded script'
if ! bash "$repo_root/.githooks/pre-push" >strict.log 2>&1; then
	cat strict.log >&2
	printf 'pre-push rejected a set -u script ending in main "$@" || exit 1\n' >&2
	exit 1
fi
printf 'PASS: pre-push accepts set -u scripts with the main guard\n'

write_sh_script bin/unguarded.sh 'main "$@"'
git add bin/unguarded.sh
git commit --quiet -m 'Add unguarded script'
if bash "$repo_root/.githooks/pre-push" >strict.log 2>&1 ||
	! grep -q 'bin/unguarded.sh missing strict mode' strict.log; then
	cat strict.log >&2
	printf 'pre-push did not reject a set -u script without the main guard\n' >&2
	exit 1
fi
printf 'PASS: pre-push rejects set -u scripts without the main guard\n'
git rm --quiet bin/unguarded.sh
git commit --quiet -m 'Remove unguarded script'

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

# Given a remote name (as Git passes it), the hook scans only commits that
# remote lacks. The branch holding the marker is still unpushed.
git init --quiet --bare "$remotes_dir/origin.git"
git remote add origin "$remotes_dir/origin.git"
git push --quiet origin main
if bash "$repo_root/.githooks/pre-push" origin >scan.log 2>&1; then
	printf 'pre-push accepted a secret in an unpushed branch\n' >&2
	exit 1
fi
printf 'PASS: pre-push rejects secrets in commits the remote lacks\n'

# Being on one remote does not make a commit safe to push to another.
git push --quiet origin outgoing
git init --quiet --bare "$remotes_dir/mirror.git"
git remote add mirror "$remotes_dir/mirror.git"
if bash "$repo_root/.githooks/pre-push" mirror >scan.log 2>&1; then
	printf 'pre-push accepted a secret that only another remote holds\n' >&2
	exit 1
fi
printf 'PASS: pre-push rejects secrets that only another remote holds\n'

printf 'still safe\n' >example.txt
git add example.txt
git commit --quiet -m 'Clean follow-up'
if ! bash "$repo_root/.githooks/pre-push" origin >scan.log 2>&1; then
	cat scan.log >&2
	printf 'pre-push rejected a clean commit on top of pushed history\n' >&2
	exit 1
fi
printf 'PASS: pre-push accepts clean commits on top of pushed history\n'
