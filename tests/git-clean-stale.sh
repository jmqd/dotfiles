#!/usr/bin/env bash
# Only old, clean, merged worktrees are trashed; everything else survives --apply.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/git-clean-stale.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HOME="$root/home" XDG_DATA_HOME="$root/home/.local/share"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME"
old="$(date -d '40 days ago' '+%Y-%m-%d %H:%M:%S')"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

git init -q -b main "$root/repo"
cd "$root/repo"
GIT_COMMITTER_DATE="$old" git commit -q --allow-empty --date="$old" -m base

# Age a worktree's checkout, index and reflog so only the threshold decides.
age() {
	local admin
	admin="$(git -C "$1" rev-parse --absolute-git-dir)"
	find "$admin" -exec touch -d "$old" {} +
}

git worktree add -q "$root/stale" -b stale main
age "$root/stale"
git worktree add -q "$root/dirty" -b dirty main
printf 'notes\n' >"$root/dirty/results.txt"
age "$root/dirty"
git worktree add -q "$root/unmerged" -b unmerged main
GIT_COMMITTER_DATE="$old" git -C "$root/unmerged" commit -q --allow-empty --date="$old" -m work
age "$root/unmerged"
# Merged with an old commit, but checked out just now.
git worktree add -q "$root/recent" -b recent main
git worktree add -q "$root/locked" -b locked main
git worktree lock "$root/locked"
age "$root/locked"

dry="$(bash "$script")"
grep -q '^stale .*/stale \[stale\]' <<<"$dry" || fail "old clean merged worktree not reported stale: $dry"
for kept in dirty unmerged recent locked; do
	grep -q "^$kept .*/$kept \[$kept\]" <<<"$dry" || fail "$kept worktree not reported $kept: $dry"
done
[[ -d $root/stale ]] || fail "dry run moved a worktree"

bash "$script" --apply >/dev/null
[[ ! -e $root/stale ]] || fail "stale worktree still in place"
trashed=("$XDG_DATA_HOME"/Trash/files/stale-*)
[[ -d ${trashed[0]} ]] || fail "stale worktree not in the trash"
records=("$XDG_DATA_HOME"/Trash/info/stale-*.trashinfo)
[[ -f ${records[0]} ]] || fail "no trashinfo record"
for kept in dirty unmerged recent locked; do
	[[ -d $root/$kept ]] || fail "$kept worktree was removed"
done
! git worktree list | grep -q "$root/stale " || fail "stale worktree still registered"
git rev-parse --verify --quiet refs/heads/stale >/dev/null || fail "branch was deleted"
grep -qx 'notes' "$root/dirty/results.txt" || fail "dirty worktree contents changed"

printf 'git-clean-stale: ok\n'
