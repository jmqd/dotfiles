#!/usr/bin/env bash
# List, and with --apply trash, linked worktrees that hold nothing worth keeping:
# HEAD already in the base branch, no tracked or untracked changes, not locked, and
# untouched for --days. Branches are left alone; emptying the trash is separate.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: git clean-stale [--apply] [--days N] [--base REF]

Reports every linked worktree of the current repository and why it is kept or
stale. A worktree is stale when all of these hold:
  - its HEAD is an ancestor of the base branch,
  - `git status --porcelain` is empty (untracked files count; ignored ones,
    such as target/, do not),
  - it is not locked,
  - its newest activity (HEAD commit, checkout, index or reflog) is older
    than --days.

  --apply    Move stale worktrees to the trash of their own filesystem, then
             run `git worktree prune`. Without it, nothing changes.
  --days N   Minimum days since last activity. Default: 14.
  --base REF Branch that work must be merged into. Default: the branch
             origin/HEAD names, else main, else master.

Sizes are what the trash would hold; space returns only when it is emptied.
USAGE
}

apply=0
days=14
base=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--apply) apply=1 ;;
	--days)
		days="${2:?--days needs a value}"
		shift
		;;
	--base)
		base="${2:?--base needs a value}"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 64
		;;
	esac
	shift
done
if [[ ! $days =~ ^[0-9]+$ ]]; then
	printf -- '--days must be a whole number, got %s\n' "$days" >&2
	exit 64
fi

# Our own `git status` must not refresh the index and so look like activity.
export GIT_OPTIONAL_LOCKS=0

resolve_base() {
	local name
	if [[ -n $base ]]; then
		git rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
			printf 'base %s is not a commit\n' "$base" >&2
			exit 1
		}
		printf '%s\n' "$base"
		return
	fi
	if name="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
		name="${name#origin/}"
		# Prefer the local branch: merges land there before they are pushed.
		if git rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then
			printf '%s\n' "$name"
		else
			printf 'origin/%s\n' "$name"
		fi
		return
	fi
	for name in main master; do
		if git rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then
			printf '%s\n' "$name"
			return
		fi
	done
	printf 'cannot find a base branch; pass --base REF\n' >&2
	exit 1
}

mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

# Newest of the HEAD commit time and the worktree's admin files. A branch made
# a minute ago has an old commit but a fresh HEAD and index.
last_activity() {
	local worktree="$1" admin newest stamp file
	newest="$(git -C "$worktree" log -1 --format=%ct HEAD 2>/dev/null || printf '0')"
	admin="$(git -C "$worktree" rev-parse --absolute-git-dir)"
	for file in "$admin/HEAD" "$admin/index" "$admin/logs/HEAD"; do
		[[ -e $file ]] || continue
		stamp="$(mtime "$file")"
		((stamp > newest)) && newest="$stamp"
	done
	printf '%s\n' "$newest"
}

mount_point() {
	df -P "$1" | awk 'NR == 2 { print $NF }'
}

# The trash on the worktree's own filesystem, so that moving frees space there
# instead of copying it elsewhere (freedesktop.org trash spec; ~/.Trash on macOS).
trash_dir() {
	local path="$1" home_trash mount uid
	uid="$(id -u)"
	if [[ "$(uname -s)" == Darwin ]]; then
		home_trash="$HOME/.Trash"
	else
		home_trash="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
	fi
	mkdir -p "$home_trash"
	mount="$(mount_point "$path")"
	if [[ "$mount" == "$(mount_point "$home_trash")" ]]; then
		printf '%s\n' "$home_trash"
	elif [[ "$(uname -s)" == Darwin ]]; then
		printf '%s/.Trashes/%s\n' "${mount%/}" "$uid"
	else
		printf '%s/.Trash-%s\n' "${mount%/}" "$uid"
	fi
}

trash() {
	local path="$1" trash name files
	trash="$(trash_dir "$path")"
	files="$trash"
	[[ "$(uname -s)" == Darwin ]] || files="$trash/files"
	mkdir -p "$files"
	name="$(basename "$path")-$(date +%Y%m%d%H%M%S)-$$"
	mv -- "$path" "$files/$name"
	if [[ "$(uname -s)" != Darwin ]]; then
		mkdir -p "$trash/info"
		printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$path" "$(date +%Y-%m-%dT%H:%M:%S)" \
			>"$trash/info/$name.trashinfo"
	fi
	printf '%s\n' "$files/$name"
}

main() {
	git rev-parse --git-dir >/dev/null
	local base_ref now cutoff main_worktree current
	base_ref="$(resolve_base)"
	now="$(date +%s)"
	cutoff=$((now - days * 86400))
	current="$(git rev-parse --show-toplevel)"

	local -a paths=() branches=() locked=()
	local line path="" branch="" lock=0
	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			path="${line#worktree }"
			branch="(detached)"
			lock=0
			;;
		"branch "*) branch="${line#branch refs/heads/}" ;;
		locked*) lock=1 ;;
		"")
			# Records end with a blank line; the extra one below closes the last
			# record if the output lacks it, and must not repeat it.
			[[ -n $path ]] || continue
			paths+=("$path")
			branches+=("$branch")
			locked+=("$lock")
			path=""
			;;
		esac
	done < <(git worktree list --porcelain && printf '\n')
	main_worktree="${paths[0]}"

	printf 'base: %s; stale after %s days%s\n' "$base_ref" "$days" \
		"$([[ $apply -eq 1 ]] && printf ', applying' || printf ', dry run')"
	local index status age_days size_kb total_kb=0 count=0 activity
	for index in "${!paths[@]}"; do
		path="${paths[$index]}"
		[[ $path == "$main_worktree" ]] && continue
		size_kb=0
		activity=""
		if [[ ! -d $path ]]; then
			status="missing (git worktree prune removes it)"
		elif [[ $path == "$current" ]]; then
			status="current"
		elif [[ ${locked[$index]} -eq 1 ]]; then
			status="locked"
		elif ! git merge-base --is-ancestor "$(git -C "$path" rev-parse HEAD)" "$base_ref"; then
			status="unmerged"
		elif [[ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -1)" ]]; then
			status="dirty"
		else
			activity="$(last_activity "$path")"
			if ((activity > cutoff)); then
				status="recent"
			else
				status="stale"
			fi
		fi
		if [[ -z $activity && -d $path ]]; then
			activity="$(last_activity "$path")"
		fi
		age_days="-"
		[[ -n $activity ]] && age_days=$(((now - activity) / 86400))
		if [[ -d $path ]]; then
			size_kb="$(du -sk "$path" 2>/dev/null | awk '{ print $1 }')"
		fi
		printf '%-8s %7s MiB %5sd  %s [%s]\n' "${status%% *}" "$((size_kb / 1024))" "$age_days" \
			"$path" "${branches[$index]}"
		if [[ $status == stale ]]; then
			total_kb=$((total_kb + size_kb))
			count=$((count + 1))
			if [[ $apply -eq 1 ]]; then
				printf '         -> %s\n' "$(trash "$path")"
			fi
		fi
	done

	if [[ $apply -eq 1 ]]; then
		git worktree prune
		printf '%d stale worktrees (%d MiB) moved to trash; empty it to free the space.\n' \
			"$count" "$((total_kb / 1024))"
	else
		printf '%d stale worktrees (%d MiB); rerun with --apply to trash them.\n' \
			"$count" "$((total_kb / 1024))"
	fi
}

main
