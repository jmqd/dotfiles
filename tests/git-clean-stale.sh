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
old_epoch=$(($(date +%s) - 40 * 86400))
if date --version >/dev/null 2>&1; then
	old="$(date -u -d "@$old_epoch" '+%Y-%m-%d %H:%M:%S +0000')"
	old_touch="$(date -u -d "@$old_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
else
	old="$(date -u -r "$old_epoch" '+%Y-%m-%d %H:%M:%S +0000')"
	old_touch="$(date -u -r "$old_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
fi

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

git init -q -b main "$root/repo"
cd "$root/repo"
GIT_COMMITTER_DATE="$old" git commit -q --allow-empty --date="$old" -m base

# Repositories with no linked worktrees and --help must exit cleanly.
bash "$script" --help >/dev/null || fail "--help failed"
empty_dry="$(bash "$script")" || fail "0-worktree dry run failed"
grep -q '^0 stale worktrees' <<<"$empty_dry" || fail "0-worktree dry run unexpected output: $empty_dry"

# Age a worktree's checkout, index and reflog so only the threshold decides.
age() {
	local admin
	admin="$(git -C "$1" rev-parse --absolute-git-dir)"
	find "$admin" -exec touch -d "$old_touch" {} +
}

git worktree add -q "$root/stale" -b stale main
age "$root/stale"
# A prompt's `git status` refreshes the index; that is not activity.
touch "$(git -C "$root/stale" rev-parse --absolute-git-dir)/index"
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
# macOS keeps trashed items directly in ~/.Trash with no trashinfo records.
if [[ "$(uname -s)" == Darwin ]]; then
	trashed=("$HOME"/.Trash/stale-*)
	[[ -d ${trashed[0]} ]] || fail "stale worktree not in the trash"
else
	trashed=("$XDG_DATA_HOME"/Trash/files/stale-*)
	[[ -d ${trashed[0]} ]] || fail "stale worktree not in the trash"
	records=("$XDG_DATA_HOME"/Trash/info/stale-*.trashinfo)
	[[ -f ${records[0]} ]] || fail "no trashinfo record"
fi
for kept in dirty unmerged recent locked; do
	[[ -d $root/$kept ]] || fail "$kept worktree was removed"
done
! git worktree list | grep -q "$root/stale " || fail "stale worktree still registered"
git rev-parse --verify --quiet refs/heads/stale >/dev/null || fail "branch was deleted"
grep -qx 'notes' "$root/dirty/results.txt" || fail "dirty worktree contents changed"

# A trash that cannot be created keeps the worktree and fails the run.
git worktree add -q "$root/stuck" -b stuck main
age "$root/stuck"
mkdir -p "$root/blocked"
if [[ "$(uname -s)" == Darwin ]]; then
	blocker="$root/blocked/.Trash"
	blocked_env=(HOME="$root/blocked")
else
	blocker="$root/blocked/Trash"
	blocked_env=(XDG_DATA_HOME="$root/blocked")
fi
: >"$blocker"
set +e
env "${blocked_env[@]}" bash "$script" --apply >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "a failed move reported success"
[[ -d $root/stuck ]] || fail "worktree lost when its move failed"
git worktree list | grep -q "$root/stuck " || fail "unmoved worktree was unregistered"
[[ -f $blocker ]] || fail "the blocking file was replaced"
! find "$root/blocked" -name 'stuck-*.trashinfo' | grep -q . || fail "a failed move left a trash record"

# A worktree whose state cannot be read is kept, however old: here a corrupt index
# fails `git status`, and a broken per-worktree config fails the activity lookup.
git worktree add -q "$root/corrupt" -b corrupt main
printf 'notes\n' >"$root/corrupt/results.txt"
printf 'garbage' >"$(git -C "$root/corrupt" rev-parse --absolute-git-dir)/index"
git config extensions.worktreeConfig true
git worktree add -q "$root/unreadable" -b unreadable main
git -C "$root/unreadable" config --worktree log.date bogus
report="$(bash "$script" --apply --days 0 2>/dev/null)"
for kept in corrupt unreadable; do
	grep -q "^unknown .*/$kept \[$kept\]" <<<"$report" || fail "$kept worktree not reported unknown: $report"
	[[ -d $root/$kept ]] || fail "$kept worktree was removed"
done
grep -qx 'notes' "$root/corrupt/results.txt" || fail "corrupt worktree lost its untracked file"

printf 'git-clean-stale: ok\n'
