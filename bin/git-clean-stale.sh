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
A worktree whose status or activity cannot be read is reported unknown and
kept.

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

os_name="$(uname -s)"
if stat -c %Y / >/dev/null 2>&1; then
	gnu_stat=1
else
	gnu_stat=0
fi

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

# Fails when stat cannot read the file.
mtime() {
	if [[ $gnu_stat -eq 1 ]]; then
		stat -c %Y "$1"
	else
		stat -f %m "$1"
	fi
}

# Newest of the HEAD commit time and the last time HEAD moved (checkout, commit,
# reset). A branch made a minute ago has an old commit but a fresh HEAD. The index
# is left out: shell prompts and editors refresh it with no real activity. Fails,
# printing nothing, when any lookup fails; callers test it in an `if`, which disables
# errexit, so every step returns on failure.
last_activity() {
	local worktree="$1" admin newest stamp file
	newest="$(git -C "$worktree" -c core.fsmonitor=false log -1 --format=%ct HEAD)" || return
	admin="$(git -C "$worktree" -c core.fsmonitor=false rev-parse --absolute-git-dir)" || return
	for file in "$admin/HEAD" "$admin/logs/HEAD"; do
		[[ -e $file ]] || continue
		stamp="$(mtime "$file")" || return
		if ((stamp > newest)); then
			newest="$stamp"
		fi
	done
	printf '%s\n' "$newest"
}

mount_point() {
	df -P "$1" | awk 'NR == 2 { print $NF }'
}

existing_ancestor() {
	local path="$1"
	while [[ ! -e $path ]]; do
		path="$(dirname "$path")"
	done
	printf '%s\n' "$path"
}

home_trash() {
	if [[ "$os_name" == Darwin ]]; then
		printf '%s\n' "$HOME/.Trash"
	else
		printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
	fi
}

# The trash on the worktree's own filesystem, so moving frees space there instead of
# copying it elsewhere: the home trash, or on Linux `.Trash-$UID` at the root of another
# writable mount. Fails when there is none; such worktrees are kept.
trash_dir() {
	local mount home
	mount="$(mount_point "$1")"
	home="$(home_trash)"
	if [[ "$mount" == "$(mount_point "$(existing_ancestor "$home")")" ]]; then
		printf '%s\n' "$home"
	elif [[ "$os_name" != Darwin && -w $mount ]]; then
		printf '%s/.Trash-%s\n' "${mount%/}" "$(id -u)"
	else
		return 1
	fi
}

# Moves `path` into `trash` and prints its new location. Callers test this in an `if`,
# which disables errexit, so every step returns on failure.
trash() {
	local path="$1" trash="$2" files="$2" name info=""
	[[ "$os_name" == Darwin ]] || files="$trash/files"
	name="$(basename "$path")-$(date +%Y%m%d%H%M%S)-$$"
	mkdir -p "$files" || return 1
	if [[ "$os_name" != Darwin ]]; then
		# The trash spec records the origin before the move.
		info="$trash/info/$name.trashinfo"
		mkdir -p "$trash/info" || return 1
		printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$path" "$(date +%Y-%m-%dT%H:%M:%S)" \
			>"$info" || return 1
	fi
	if ! mv -- "$path" "$files/$name"; then
		[[ -z $info ]] || rm -f -- "$info"
		return 1
	fi
	printf '%s\n' "$files/$name"
}

sizes_dir=""
cleanup() {
	[[ -n $sizes_dir ]] && rm -rf "$sizes_dir"
}
trap cleanup EXIT

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

	# Measure existing linked worktree sizes in parallel up front.
	local -a size_paths=()
	local index
	for index in "${!paths[@]}"; do
		path="${paths[$index]}"
		[[ $path == "$main_worktree" ]] && continue
		[[ -d $path ]] && size_paths+=("$path")
	done
	local sizes_file="" jobs
	if [[ ${#size_paths[@]} -gt 0 ]]; then
		sizes_dir="$(mktemp -d)"
		mkdir -p "$sizes_dir/items"
		sizes_file="$sizes_dir/all"
		jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
		case "$jobs" in '' | 0 | *[!0-9]*) jobs=4 ;; esac
		# shellcheck disable=SC2016 # $0, $1, and $$ expand inside the child bash
		printf '%s\0' "${size_paths[@]}" | xargs -0 -n 1 -P "$jobs" \
			"$BASH" -c 'du -sk -- "$1" >>"$0/$$" 2>/dev/null' "$sizes_dir/items" || true
		find "$sizes_dir/items" -type f -exec cat {} + >"$sizes_file" 2>/dev/null || true
	fi

	printf 'base: %s; stale after %s days%s\n' "$base_ref" "$days" \
		"$([[ $apply -eq 1 ]] && printf ', applying' || printf ', dry run')"
	local status age_days size_kb total_kb=0 count=0 failed=0 activity porcelain trash dest
	for index in "${!paths[@]}"; do
		path="${paths[$index]}"
		[[ $path == "$main_worktree" ]] && continue
		size_kb=0
		activity=""
		if [[ -d $path ]] && ! activity="$(last_activity "$path")"; then
			activity=""
		fi
		if [[ ! -d $path ]]; then
			status="missing (git worktree prune removes it)"
		elif [[ $path == "$current" ]]; then
			status="current"
		elif [[ ${locked[$index]} -eq 1 ]]; then
			status="locked"
		elif ! git merge-base --is-ancestor "$(git -C "$path" -c core.fsmonitor=false rev-parse HEAD)" "$base_ref"; then
			status="unmerged"
		elif ! porcelain="$(git -C "$path" -c core.fsmonitor=false status --porcelain)"; then
			status="unknown"
		elif [[ -n $porcelain ]]; then
			status="dirty"
		elif [[ -z $activity ]]; then
			# last_activity failed and said why on stderr.
			status="unknown"
		elif ((activity > cutoff)); then
			status="recent"
		else
			status="stale"
		fi
		age_days="-"
		[[ -n $activity ]] && age_days=$(((now - activity) / 86400))
		if [[ -d $path && -s $sizes_file ]]; then
			size_kb="$(awk -v p="$path" 'substr($0, index($0, "\t") + 1) == p { print $1; exit }' "$sizes_file")"
			[[ -n $size_kb ]] || size_kb=0
		fi
		if [[ $status == stale ]] && ! trash="$(trash_dir "$path")"; then
			status="no-trash"
		fi
		printf '%-8s %7s MiB %5sd  %s [%s]\n' "${status%% *}" "$((size_kb / 1024))" "$age_days" \
			"$path" "${branches[$index]}"
		[[ $status == stale ]] || continue
		if [[ $apply -eq 0 ]]; then
			total_kb=$((total_kb + size_kb))
			count=$((count + 1))
		elif dest="$(trash "$path" "$trash")"; then
			printf '         -> %s\n' "$dest"
			total_kb=$((total_kb + size_kb))
			count=$((count + 1))
		else
			printf '         could not move it to %s; kept\n' "$trash" >&2
			failed=$((failed + 1))
		fi
	done

	if [[ $apply -eq 1 ]]; then
		git worktree prune
		printf '%d stale worktrees (%d MiB) moved to trash; empty it to free the space.\n' \
			"$count" "$((total_kb / 1024))"
		if ((failed > 0)); then
			printf '%d stale worktrees could not be moved.\n' "$failed" >&2
			exit 1
		fi
	else
		printf '%d stale worktrees (%d MiB); rerun with --apply to trash them.\n' \
			"$count" "$((total_kb / 1024))"
	fi
}

main
