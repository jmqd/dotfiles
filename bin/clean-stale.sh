#!/usr/bin/env bash
# Deletes regenerable files that nothing has touched for a while. Runs on
# macOS and Linux with bash 3.2+ and either GNU or BSD userland tools.
set -euo pipefail

readonly default_age=36h
# The README's policy: the current generation and four rollbacks.
readonly keep_generations=5
readonly tab=$'\t'
readonly nl=$'\n'

usage() {
	cat <<EOF
usage: $(basename "$0") [-n | --dry-run] [-y | --yes] [--age AGE] [--root DIR]...

Delete regenerable files that nothing has touched for AGE (default
${default_age}). The plan is printed first; nothing is deleted until you
confirm it.

Deletes, once idle for AGE:
  - Rust target dirs, or the idle profiles and task dirs inside them
  - other tagged build caches (.pytest_cache, .mypy_cache, ...)
  - per-app caches in ~/Library/Caches and ~/.cache, package caches
    (npm, bun, yarn, Go modules, rustup downloads), Xcode DerivedData
  - your files in the temp directories
  - linked git worktrees that are clean, whose HEAD a branch, tag, or
    remote holds, and whose ignored files are all build output
  - omp task copies whose owning process has exited
  - git worktree entries whose directories are gone
  - nix result* out-links and direnv layout dirs (.direnv), except dev
    shells of projects a process works in
  - nix profile generations past the newest ${keep_generations}
  - versioned rustup toolchains (1.85.0, nightly-2026-01-01) that no
    default, override, rust-toolchain file, or dylint driver selects

Then runs the garbage collectors it finds: docker and podman image prune
(images no container uses, created before AGE ago) and docker builder
prune (build cache unused for AGE), keeping containers, networks, and
volumes; flatpak uninstall --unused; xcrun simctl delete unavailable; and
nix-store --gc last.

Keeps anything written, renamed, or held open by a process within AGE;
anything containing a socket or FIFO; empty files and directories; caches
that hold installs or models (playwright, puppeteer, huggingface, ...);
anything in the trash; and any git checkout with uncommitted changes,
stashes, or commits no remote or tag holds. Reads count only where the
filesystem records them: Linux relatime records at most one read a day,
and macOS records only the first read after each change.

options:
  -n, --dry-run   print the plan and exit
  -y, --yes       delete without asking (required when stdin is not a TTY)
      --age AGE   idle threshold: N or Nh hours, Nd days (default ${default_age})
      --root DIR  search DIR for projects instead of \$HOME (repeatable)
  -h, --help      show this help
EOF
}

die() {
	printf 'clean-stale: %s\n' "$*" >&2
	exit 2
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

section() {
	printf '\n==> %s\n' "$*"
}

# Parses N, Nh, or Nd (at most six digits) into minutes.
parse_age_minutes() {
	local value="$1" number factor=60
	case "$value" in
	*d)
		number="${value%d}"
		factor=1440
		;;
	*h) number="${value%h}" ;;
	*) number="$value" ;;
	esac
	case "$number" in
	'' | 0* | *[!0-9]* | ???????*) return 1 ;;
	esac
	printf '%s\n' "$((number * factor))"
}

canonical_dir() {
	(cd -P -- "$1" 2>/dev/null && pwd)
}

dry_run=0
assume_yes=0
age="$default_age"
roots=()
while [ $# -gt 0 ]; do
	case "$1" in
	-n | --dry-run) dry_run=1 ;;
	-y | --yes) assume_yes=1 ;;
	--age)
		[ $# -ge 2 ] || die "--age needs a value"
		age="$2"
		shift
		;;
	--age=*) age="${1#--age=}" ;;
	--root)
		[ $# -ge 2 ] || die "--root needs a directory"
		roots+=("$2")
		shift
		;;
	--root=*) roots+=("${1#--root=}") ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
	shift
done

age_minutes="$(parse_age_minutes "$age")" || die "invalid --age '$age' (use N, Nh, or Nd)"

uid="$(id -u)"
os="$(uname -s)"
home="$(canonical_dir "$HOME")" || die "cannot resolve HOME ($HOME)"
cache_home="${XDG_CACHE_HOME:-$home/.cache}"
data_home="${XDG_DATA_HOME:-$home/.local/share}"
cargo_home="${CARGO_HOME:-$home/.cargo}"
rustup_home="${RUSTUP_HOME:-$home/.rustup}"

if [ ${#roots[@]} -eq 0 ]; then
	roots=("$home")
fi
search_roots=()
for root in "${roots[@]}"; do
	resolved="$(canonical_dir "$root")" || die "not a directory: $root"
	search_roots+=("$resolved")
done

# System temp directories only: an arbitrary TMPDIR could be a project tree.
# CLEAN_STALE_TEMP_ROOTS (colon-separated) replaces them for tests.
temp_candidates() {
	if [ -n "${CLEAN_STALE_TEMP_ROOTS+x}" ]; then
		printf '%s\n' "$CLEAN_STALE_TEMP_ROOTS" | tr ':' '\n'
		return
	fi
	if [ "$os" = Darwin ]; then
		getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true
	fi
	printf '%s\n' /tmp /var/tmp
}
temp_roots=()
while IFS= read -r dir; do
	[ -n "$dir" ] || continue
	resolved="$(canonical_dir "$dir")" || continue
	# Every idle entry of a temp root goes, so none may hold HOME or sit in it.
	case "$resolved" in
	/ | "$home" | "$home"/*)
		warn "skipping temp dir $resolved: it is / or inside HOME"
		continue
		;;
	esac
	case "$home/" in
	"$resolved"/*)
		warn "skipping temp dir $resolved: it contains HOME"
		continue
		;;
	esac
	known=0
	for existing in ${temp_roots[@]+"${temp_roots[@]}"}; do
		if [ "$existing" = "$resolved" ]; then
			known=1
		fi
	done
	if [ "$known" -eq 0 ]; then
		temp_roots+=("$resolved")
	fi
done < <(temp_candidates)

if date --version >/dev/null 2>&1; then
	gnu_date=1
else
	gnu_date=0
fi
if stat -c %d / >/dev/null 2>&1; then
	gnu_stat=1
else
	gnu_stat=0
fi
if rm --version >/dev/null 2>&1; then
	rm_one_fs=--one-file-system
else
	rm_one_fs=-x
fi
have_git=0
if command -v git >/dev/null 2>&1; then
	have_git=1
fi
# omp_owner_alive needs process start times; BusyBox ps has no lstart.
have_ps=0
if ps -o lstart= -p $$ >/dev/null 2>&1; then
	have_ps=1
fi
# Filesystem walks run this many at a time.
parallel_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
case "$parallel_jobs" in '' | 0 | *[!0-9]*) parallel_jobs=4 ;; esac

# Runs date(1) for epoch second $1 with the remaining options and format.
date_at() {
	local epoch="$1"
	shift
	if [ "$gnu_date" -eq 1 ]; then
		date -d "@$epoch" "$@"
	else
		date -r "$epoch" "$@"
	fi
}

# Succeeds when PATH sits on its parent directory's filesystem, so it is
# no mount point.
on_parent_fs() {
	local devices lf=$'\n'
	if [ "$gnu_stat" -eq 1 ]; then
		devices="$(stat -c %d -- "$1" "${1%/*}" 2>/dev/null)" || return 1
	else
		devices="$(stat -f %d -- "$1" "${1%/*}" 2>/dev/null)" || return 1
	fi
	[ "${devices%%"$lf"*}" = "${devices#*"$lf"}" ]
}

work="$(mktemp -d "${TMPDIR:-/tmp}/clean-stale.XXXXXX")"
trap 'rm -rf "$work"' EXIT
plan="$work/plan"
open_paths="$work/open-paths"
notes="$work/notes"
contained="$work/contained"
: >"$plan"
: >"$notes"

# CLEAN_STALE_NOW (epoch seconds) moves the clock for tests.
now="${CLEAN_STALE_NOW:-$(date +%s)}"
case "$now" in '' | *[!0-9]*) die "CLEAN_STALE_NOW must be epoch seconds" ;; esac
cutoff_epoch=$((now - age_minutes * 60))
git_expire="$(date_at "$cutoff_epoch" -u '+%Y-%m-%d %H:%M:%S +0000')"

current_epoch() {
	printf '%s\n' "${CLEAN_STALE_NOW:-$(date +%s)}"
}

set_mtime() {
	touch -d "$(date_at "$1" -u +%Y-%m-%dT%H:%M:%SZ)" "$2"
}

# Reference files for find's -newer tests. A read counts as use only
# inside a window: from the cutoff to the start of the scan while
# planning, and after planning while deleting. Reads that git makes
# during this run (racily clean files, copied repos) then do not count.
cutoff="$work/cutoff"
scan_start="$work/scan-start"
plan_done="$work/plan-done"
set_mtime "$cutoff_epoch" "$cutoff"
set_mtime "$now" "$scan_start"
reads_after="$cutoff"
reads_before="$scan_start"

# Succeeds when nothing at or below PATH was modified or changed after the
# cutoff, no file there was read inside the read window, and no socket or
# FIFO lives there. A tree we cannot fully read counts as busy. Reads of
# what this tool reads itself (cache tags, omp owner records, toolchain
# pins, git metadata) never count; Linux relatime records those reads, so
# a run would otherwise mark them busy for the next run.
is_idle() {
	local hit window=(
		! -type d ! -name CACHEDIR.TAG ! -name .omp-isolation-owner.json
		! -name rust-toolchain ! -name rust-toolchain.toml
		! -name '.git*' ! -path '*/.git/*' -neweram "$reads_after"
	)
	if [ -n "$reads_before" ]; then
		window+=(! -neweram "$reads_before")
	fi
	hit="$(find "$1" -xdev \( -type s -o -type p -o -newermm "$cutoff" -o -newercm "$cutoff" -o \( "${window[@]}" \) \) -print -quit 2>/dev/null)" || return 1
	[ -z "$hit" ]
}

# Lists every path our processes hold open or work in, plus all parents,
# so a directory is in use exactly when its path appears. Only absolute
# paths count: /proc also links to sockets, pipes, and anonymous inodes.
snapshot_open_paths() {
	{
		if command -v lsof >/dev/null 2>&1; then
			lsof -nP -w -u "$uid" -Fn 2>/dev/null | sed -n 's|^n\(/.*\)|\1|p' || true
		elif [ -d /proc/self/fd ]; then
			local proc
			for proc in /proc/[0-9]*; do
				[ -O "$proc" ] || continue
				readlink -- "$proc/cwd" "$proc/exe" "$proc"/fd/* 2>/dev/null || true
			done
		else
			warn "cannot list open files (no lsof or /proc); relying on timestamps alone"
		fi
	} | awk '
		!/^\// { next }
		{ p = $0; sub(/ \(deleted\)$/, "", p); while (p != "" && p != "/") { print p; sub(/\/[^\/]*$/, "", p) } }
	' | LC_ALL=C sort -u >"$open_paths"
}

in_use() {
	grep -Fxq -- "$1" "$open_paths"
}

# Rejects names that would break the tab- and newline-separated plan.
safe_path() {
	case "$1" in *"$nl"* | *"$tab"*) return 1 ;; esac
}

# Succeeds when PATH is a non-empty regular file or directory that we own,
# sits on its parent's filesystem, is not held open, and is idle.
check_plannable() {
	local path="$1"
	[ ! -L "$path" ] || return 1
	if [ -d "$path" ]; then
		[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || return 1
		on_parent_fs "$path" || return 1
	elif [ -f "$path" ]; then
		[ -s "$path" ] || return 1
	else
		return 1
	fi
	[ -O "$path" ] || return 1
	! in_use "$path" || return 1
	is_idle "$path"
}

# Results prefetch_plannable computed ahead, as newline-delimited sets.
# execute_plan clears them, so each deletion rechecks its path just
# before it acts.
plannable_yes="$nl"
plannable_no="$nl"

plannable() {
	case "$plannable_yes" in *"$nl$1$nl"*) return 0 ;; esac
	case "$plannable_no" in *"$nl$1$nl"*) return 1 ;; esac
	check_plannable "$1"
}

# Prints check_plannable's verdict on each argument: 1 or 0, a tab, and
# the path.
probe_paths() {
	local path
	for path; do
		if check_plannable "$path"; then
			printf '1\t%s\n' "$path"
		else
			printf '0\t%s\n' "$path"
		fi
	done
}

# Runs bash CODE on the NUL-separated arguments on stdin, at most COUNT
# per run and $parallel_jobs runs at a time, then prints all output. Each
# run writes its own file: POSIX keeps concurrent pipe writes whole only
# up to PIPE_BUF (512 bytes on macOS), and find writes larger blocks.
parallel_runs() {
	local count="$1" code="$2" out
	out="$(mktemp -d "$work/runs.XXXXXX")"
	xargs -0 -n "$count" -P "$parallel_jobs" "$BASH" -c "{
$code
} >>\"\$0/\$\$\"" "$out" 2>/dev/null || true
	find "$out" -type f -exec cat {} + 2>/dev/null || true
}

# Passes on the NUL-separated paths from stdin that plannable has no
# verdict for and that fit the line-based results.
unprobed_paths() {
	local path
	while IFS= read -r -d '' path; do
		safe_path "$path" || continue
		case "$plannable_yes$plannable_no" in *"$nl$path$nl"*) continue ;; esac
		printf '%s\0' "$path"
	done
}

# Runs check_plannable on the NUL-separated paths on stdin, in parallel,
# and caches the results for plannable. Paths it skips or misses are
# checked when plannable asks.
prefetch_plannable() {
	local probe path ok
	probe="$(declare -p cutoff reads_after reads_before open_paths gnu_stat)
$(declare -f probe_paths check_plannable is_idle in_use on_parent_fs)
probe_paths \"\$@\""
	while IFS="$tab" read -r ok path; do
		if [ "$ok" = 1 ]; then
			plannable_yes="$plannable_yes$path$nl"
		else
			plannable_no="$plannable_no$path$nl"
		fi
	done < <(unprobed_paths | parallel_runs 1 "$probe")
}

# Prefetches the paths listed one per line in FILE.
prefetch_listed() {
	prefetch_plannable < <(tr '\n' '\0' <"$1")
}

# Newline-delimited planned paths, for under_planned without a process.
planned_dirs="$nl"

add() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$plan"
	case "$1" in
	path | worktree) planned_dirs="$planned_dirs$3$nl" ;;
	esac
}

# Records an idle path kept because deleting it could lose work.
note() {
	printf '%s\t%s\n' "$1" "$2" >>"$notes"
}

under_planned() {
	local parent="$1"
	while parent="${parent%/*}" && [ -n "$parent" ]; do
		case "$planned_dirs" in *"$nl$parent$nl"*) return 0 ;; esac
	done
	return 1
}

children() {
	find "$1" -mindepth 1 -maxdepth 1 "${@:2}" -print0 2>/dev/null
}

# Runs git read-only in a checkout or repository: no optional locks (so no
# index refresh), no fsmonitor daemon, and untranslated messages.
git_in() {
	local dir="$1"
	shift
	LC_ALL=C GIT_OPTIONAL_LOCKS=0 git -C "$dir" -c core.fsmonitor=false "$@"
}

git_repo() {
	local repo="$1"
	shift
	LC_ALL=C GIT_OPTIONAL_LOCKS=0 git --git-dir="$repo" -c core.fsmonitor=false "$@"
}

# Sets checkout_risk to why deleting the checkout at DIR could lose work,
# or to "" when git holds all of it elsewhere. Also sets checkout_linked
# (1 for a linked worktree) and checkout_common (its repository's git dir).
assess_checkout() {
	local dir="$1" git_dir="" line="" status unique
	checkout_risk=""
	checkout_linked=0
	checkout_common=""
	# A linked worktree's metadata lives in its repository; check it for
	# use before git reads it.
	if [ -f "$dir/.git" ]; then
		read -r line <"$dir/.git" 2>/dev/null || true
		case "$line" in "gitdir: "*) git_dir="${line#gitdir: }" ;; esac
		case "$git_dir" in
		"" | /*) ;;
		*) git_dir="$dir/$git_dir" ;;
		esac
		case "$git_dir" in */worktrees/*) checkout_linked=1 ;; esac
		if [ -n "$git_dir" ] && [ -d "$git_dir" ] && ! is_idle "$git_dir"; then
			checkout_risk="git metadata used within $age"
			return
		fi
	fi
	if [ "$have_git" -ne 1 ]; then
		checkout_risk="git is not installed"
		return
	fi
	if ! git_dir="$(git_in "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ||
		! checkout_common="$(git_in "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
		checkout_risk="not a readable git checkout"
		return
	fi
	if [ "$git_dir" != "$checkout_common" ]; then
		checkout_linked=1
	else
		checkout_linked=0
	fi
	if ! status="$(git_in "$dir" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)"; then
		checkout_risk="git status failed"
	elif [ -n "$status" ]; then
		checkout_risk="uncommitted changes"
	elif [ -e "$dir/.gitmodules" ]; then
		checkout_risk="has submodules"
	elif [ "$checkout_linked" -eq 1 ]; then
		# Branches and stashes stay in the repository; only HEAD can be lost.
		if [ -e "$git_dir/locked" ]; then
			checkout_risk="locked worktree"
		elif [ -z "$(git_in "$dir" for-each-ref --count=1 --contains HEAD --format=x refs/heads refs/remotes refs/tags 2>/dev/null || true)" ]; then
			checkout_risk="HEAD is on no branch, tag, or remote"
		fi
	elif git_in "$dir" rev-parse -q --verify refs/stash >/dev/null 2>&1; then
		checkout_risk="stashed changes"
	elif [ -n "$(find "$git_dir/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]; then
		checkout_risk="other worktrees use its repository"
	elif ! unique="$(git_in "$dir" rev-list -n 1 HEAD --branches --not --remotes --tags 2>/dev/null)"; then
		checkout_risk="cannot list its commits"
	elif [ -n "$unique" ]; then
		checkout_risk="commits no remote or tag holds"
	fi
}

assessed=()
assessed_risk=()
assessed_linked=()
assessed_common=()

# assess_checkout, once per checkout per run.
assess_cached() {
	local i=0
	while [ "$i" -lt "${#assessed[@]}" ]; do
		if [ "${assessed[$i]}" = "$1" ]; then
			checkout_risk="${assessed_risk[$i]}"
			checkout_linked="${assessed_linked[$i]}"
			checkout_common="${assessed_common[$i]}"
			return 0
		fi
		i=$((i + 1))
	done
	assess_checkout "$1"
	assessed+=("$1")
	assessed_risk+=("$checkout_risk")
	assessed_linked+=("$checkout_linked")
	assessed_common+=("$checkout_common")
}

# Succeeds when every ignored path in the checkout at DIR is build output
# or cache; otherwise sets ignored_keeper to the first one that is not.
ignored_regenerable() {
	local dir="$1" entry name
	ignored_keeper=""
	if ! git_in "$dir" status --porcelain=v1 -z --ignored=matching --untracked-files=normal >"$work/ignored" 2>/dev/null; then
		ignored_keeper="(git status failed)"
		return 1
	fi
	while IFS= read -r -d '' entry; do
		case "$entry" in '!! '*) ;; *) continue ;; esac
		entry="${entry#!! }"
		entry="${entry%/}"
		name="${entry##*/}"
		case "$name" in
		target | node_modules | __pycache__ | *.pyc | *.pyo | .pytest_cache | .mypy_cache | .ruff_cache | \
			.hypothesis | .tox | .nox | .venv | venv | *.egg-info | .eggs | .direnv | result | result-* | \
			.gradle | .next | .turbo | .parcel-cache | .DS_Store | .coverage | htmlcov)
			continue
			;;
		esac
		if [ -f "$dir/$entry/CACHEDIR.TAG" ]; then
			continue
		fi
		ignored_keeper="$entry"
		return 1
	done <"$work/ignored"
}

is_contained() {
	grep -Fxq -- "$1" "$contained"
}

# Succeeds when deleting PATH would delete a checkout holding work; sets
# blocker to that checkout and blocker_risk to why.
blocks_work() {
	local c
	[ -s "$contained" ] || return 1
	while IFS= read -r c; do
		assess_cached "$c"
		if [ -n "$checkout_risk" ]; then
			blocker="$c"
			blocker_risk="$checkout_risk"
			return 0
		fi
	done < <(P="$1/" awk 'BEGIN { p = ENVIRON["P"] } index($0 "/", p) == 1' "$contained")
	return 1
}

# Plans PATH when it is plannable. When deleting it would take a checkout
# holding work with it, plans the rest of PATH around that checkout.
plan_path() {
	local label="$1" path="$2" child
	plannable "$path" || return 0
	if ! blocks_work "$path"; then
		add path "$label" "$path"
		return 0
	fi
	if [ "$blocker" = "$path" ]; then
		note "$blocker" "$blocker_risk"
		return 0
	fi
	while IFS= read -r -d '' child; do
		safe_path "$child" || continue
		plan_path "$label" "$child"
	done < <(children "$path")
}

# Plans each idle entry directly inside DIR.
plan_entries() {
	local label="$1" dir="$2" entry
	[ -d "$dir" ] && [ ! -L "$dir" ] || return 0
	prefetch_plannable < <(children "$dir")
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		plan_path "$label" "$entry"
	done < <(children "$dir")
}

# Walks each directory argument, unless it is a mount point, with the
# find expression in discover_expr, skipping the directory itself.
discover_below() {
	local dir
	for dir; do
		on_parent_fs "$dir" || continue
		find "$dir" -mindepth 1 -xdev "${discover_expr[@]}" 2>/dev/null || true
	done
}

# Prints, NUL-separated, every CACHEDIR.TAG, .git, rust-toolchain file,
# direnv layout dir, and result* symlink under the search and temp roots.
# Trees that cannot hold projects are pruned. One find covers the top two
# levels of every root; the directories it reaches at the second level
# (each project under ~/src) are then walked in parallel.
discover() {
	local root dir walker discover_expr skip prune=(
		-name node_modules -o
		-name deps -o -name .fingerprint -o -name incremental -o
		-name .Trashes -o -name ".Trash-$uid" -o -path "$home/.Trash" -o -path "$data_home/Trash" -o
		-path "$home/Library" -o
		-path "$home/Pictures" -o -path "$home/Music" -o -path "$home/Movies" -o
		-path "$cache_home" -o -path "$cargo_home" -o -path "$rustup_home" -o
		-path "$home/.npm" -o -path "$home/.nix-defexpr"
	)
	skip=(\( \( -name .git -o -name .direnv \) -type d -prune \) -o \( \( "${prune[@]}" \) -prune \))
	discover_expr=(
		\( \( -name .git -o -name .direnv \) -type d -print0 -prune \) -o
		\( \( "${prune[@]}" \) -prune \) -o
		\( -type f \( -name CACHEDIR.TAG -o -name .git -o -name rust-toolchain -o -name rust-toolchain.toml \) -print0 \) -o
		\( -type l \( -name result -o -name 'result-*' \) -print0 \)
	)
	walker="$(declare -p discover_expr gnu_stat)
$(declare -f discover_below on_parent_fs)
discover_below \"\$@\""
	find "${search_roots[@]}" ${temp_roots[@]+"${temp_roots[@]}"} -xdev -maxdepth 2 \
		"${discover_expr[@]}" 2>/dev/null || true
	for root in "${search_roots[@]}" ${temp_roots[@]+"${temp_roots[@]}"}; do
		while IFS= read -r -d '' dir; do
			[ "$dir" != "$root" ] || continue
			case "${dir#"${root%/}"/}" in */*) printf '%s\0' "$dir" ;; esac
		done < <(find "$root" -xdev -maxdepth 2 "${skip[@]}" -o \( -type d -print0 \) 2>/dev/null || true)
	done | parallel_runs 1 "$walker"
}

# Splits discoveries into cargo target dirs (cargo's tag plus
# .rustc_info.json; vendored crates and CARGO_HOME carry only the tag),
# other tagged caches, git checkouts, direnv layout dirs, nix out-links,
# and toolchain pins.
classify_discoveries() {
	local path dir list
	for list in rust-targets build-caches checkouts direnvs outlinks pins; do
		: >"$work/$list.unsorted"
	done
	while IFS= read -r -d '' path; do
		safe_path "$path" || continue
		dir="${path%/*}"
		case "$path" in
		*/CACHEDIR.TAG)
			[ "$(head -c 43 "$path" 2>/dev/null)" = "Signature: 8a477f597d28d172789f06886806bc55" ] || continue
			if grep -q 'created by cargo' "$path" 2>/dev/null; then
				if [ -f "$dir/.rustc_info.json" ]; then
					printf '%s\n' "$dir" >>"$work/rust-targets.unsorted"
				fi
			elif [ ! -e "$dir/pyvenv.cfg" ]; then
				# uv tags virtualenvs; those are environments, not caches.
				printf '%s\n' "$dir" >>"$work/build-caches.unsorted"
			fi
			;;
		*/.git) printf '%s\n' "$dir" >>"$work/checkouts.unsorted" ;;
		*/.direnv) printf '%s\n' "$path" >>"$work/direnvs.unsorted" ;;
		*/result | */result-*)
			case "$(readlink -- "$path" 2>/dev/null || true)" in
			/nix/store/*) printf '%s\n' "$path" >>"$work/outlinks.unsorted" ;;
			esac
			;;
		*) printf '%s\n' "$path" >>"$work/pins.unsorted" ;;
		esac
	done
	for list in rust-targets build-caches checkouts direnvs outlinks pins; do
		LC_ALL=C sort -u "$work/$list.unsorted" >"$work/$list"
	done
}

# Collects the checkouts inside directories this run may delete whole:
# build output, temp directories, and omp task copies.
find_contained_checkouts() {
	{
		cat "$work/rust-targets" "$work/build-caches"
		printf '%s\n' "$home/.omp/wt" ${temp_roots[@]+"${temp_roots[@]}"}
	} >"$work/containers"
	awk '
		NR == FNR { container[$0] = 1; next }
		{ p = $0; while (sub(/\/[^\/]*$/, "", p) && p != "") if (p in container) { print; next } }
	' "$work/containers" "$work/checkouts" >"$contained"
}

# Prints, NUL-separated, the entries of each target dir not already
# planned whole: the paths plan_rust_targets checks one by one.
busy_target_entries() {
	local target
	while IFS= read -r target; do
		if ! under_planned "$target" && ! plannable "$target"; then
			children "$target"
		fi
	done <"$work/rust-targets"
}

# Plans an idle target dir whole; otherwise plans its idle profiles, task
# dirs, and loose files. Nested target dirs get their own pass.
# shellcheck disable=SC2094 # the loop and the nested check only read the list
plan_rust_targets() {
	local target entry
	prefetch_listed "$work/rust-targets"
	prefetch_plannable < <(busy_target_entries)
	while IFS= read -r target <&3; do
		if under_planned "$target"; then
			continue
		fi
		if plannable "$target" && ! blocks_work "$target"; then
			add path rust "$target"
			continue
		fi
		while IFS= read -r -d '' entry; do
			case "${entry##*/}" in CACHEDIR.TAG | .rustc_info.json) continue ;; esac
			safe_path "$entry" || continue
			if grep -Fxq -- "$entry" "$work/rust-targets"; then
				continue
			fi
			plan_path rust "$entry"
		done < <(children "$target")
	done 3<"$work/rust-targets"
}

plan_build_caches() {
	local dir
	prefetch_listed "$work/build-caches"
	while IFS= read -r dir <&3; do
		plan_path build-cache "$dir"
	done 3<"$work/build-caches"
}

# Nix keeps one eval cache per flake revision, so idle ones go even while
# the directory stays busy.
plan_nix_cache() {
	local entry
	prefetch_plannable < <(
		children "$1"
		for entry in "$1"/eval-cache-v*; do
			if [ -d "$entry" ] && [ ! -L "$entry" ]; then
				children "$entry"
			fi
		done
	)
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		if plannable "$entry"; then
			add path cache "$entry"
		elif [ -d "$entry" ] && [ ! -L "$entry" ]; then
			case "${entry##*/}" in eval-cache-v*) plan_entries cache "$entry" ;; esac
		fi
	done < <(children "$1")
}

# Prints, NUL-separated, the plain app caches in cache root DIR: not
# system state, not installs or models that tools do not fetch again on
# demand, and not nix, which plan_nix_cache handles.
cache_root_entries() {
	local entry
	while IFS= read -r -d '' entry; do
		case "${entry##*/}" in
		com.apple.* | CloudKit | FamilyCircle | GeoServices | PassKit | Metadata | familycircled) ;;
		ms-playwright* | puppeteer | Cypress | huggingface | torch | whisper | lm-studio | llama.cpp | gpt4all | codex-runtimes | pypoetry) ;;
		nix) ;;
		*) printf '%s\0' "$entry" ;;
		esac
	done < <(children "$1")
}

plan_cache_root() {
	local entry
	[ -d "$1" ] || return 0
	if [ -e "$1/nix" ]; then
		plan_nix_cache "$1/nix"
	fi
	prefetch_plannable < <(cache_root_entries "$1")
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		plan_path cache "$entry"
	done < <(cache_root_entries "$1")
}

plan_package_caches() {
	local gopath="${GOPATH:-$home/go}" unit
	for unit in \
		"$home/.npm/_cacache" "$home/.npm/_npx" "$home/.npm/_logs" \
		"$home/.bun/install/cache" "$home/.yarn/berry/cache" \
		"${GOMODCACHE:-${gopath%%:*}/pkg/mod}"; do
		if [ -e "$unit" ]; then
			plan_path cache "$unit"
		fi
	done
	plan_entries cache "$rustup_home/downloads"
	plan_entries cache "$rustup_home/tmp"
	# Cargo's sources and git checkouts stay: cargo cleans them by its own
	# record of use, and builds read them without leaving a trace on macOS.
}

# Prints, NUL-separated, our own entries in the temp roots. Dot-entries
# and Apple's per-daemon dirs belong to running services.
# SoftwareUpdateCore keeps macOS update state in /var/tmp, which survives
# reboots.
temp_entries() {
	local dir entry
	for dir in ${temp_roots[@]+"${temp_roots[@]}"}; do
		while IFS= read -r -d '' entry; do
			case "${entry##*/}" in
			.* | com.apple.* | TemporaryItems | SoftwareUpdateCore) ;;
			*) printf '%s\0' "$entry" ;;
			esac
		done < <(children "$dir" -user "$uid")
	done
}

plan_temp() {
	local entry
	prefetch_plannable < <(temp_entries)
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		plan_path tmp "$entry"
	done < <(temp_entries)
}

squeeze() {
	printf '%s\n' "$1" | awk '{ $1 = $1; print }'
}

# Succeeds unless the owner file names a process that has exited or whose
# pid now belongs to a process started at another time. Unknown counts as
# alive.
omp_owner_alive() {
	local json pid token started
	[ "$have_ps" -eq 1 ] || return 0
	json="$(cat "$1" 2>/dev/null)" || return 0
	pid="$(printf '%s\n' "$json" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
	[ -n "$pid" ] || return 0
	started="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
	[ -n "$started" ] || return 1
	token="$(printf '%s\n' "$json" | sed -n 's/.*"startToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
	[ -n "$token" ] || return 0
	[ "$(squeeze "$started")" = "$(squeeze "$token")" ]
}

# omp keeps each isolated task's copy in ~/.omp/wt/<id>, with the owning
# process recorded beside it. A copy whose owner has exited is an orphan.
plan_omp_isolation() {
	local dir orphans=()
	for dir in "$home"/.omp/wt/*; do
		[ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/.omp-isolation-owner.json" ] || continue
		safe_path "$dir" || continue
		if ! omp_owner_alive "$dir/.omp-isolation-owner.json"; then
			orphans+=("$dir")
		fi
	done
	[ ${#orphans[@]} -gt 0 ] || return 0
	prefetch_plannable < <(printf '%s\0' "${orphans[@]}")
	for dir in "${orphans[@]}"; do
		plannable "$dir" || continue
		if blocks_work "$dir"; then
			note "$blocker" "$blocker_risk (orphaned omp task copy)"
			continue
		fi
		add path agent "$dir"
	done
}

# Prints, NUL-separated, the checkouts with a .git file that no planned or
# deletable directory holds: the candidates of plan_worktrees.
worktree_candidates() {
	local dir
	while IFS= read -r dir; do
		[ -f "$dir/.git" ] || continue
		if ! is_contained "$dir" && ! under_planned "$dir"; then
			printf '%s\0' "$dir"
		fi
	done <"$work/checkouts"
}

# Plans removal of idle linked worktrees that hold nothing beyond what
# their repository keeps and regenerable build output.
plan_worktrees() {
	local dir
	worktree_candidates >"$work/worktree-candidates"
	prefetch_plannable <"$work/worktree-candidates"
	while IFS= read -r -d '' dir <&3; do
		if under_planned "$dir" || ! plannable "$dir"; then
			continue
		fi
		assess_cached "$dir"
		[ "$checkout_linked" -eq 1 ] || continue
		if [ -z "$checkout_risk" ] && ! ignored_regenerable "$dir"; then
			checkout_risk="ignored $ignored_keeper may not be regenerable"
		fi
		if [ -n "$checkout_risk" ]; then
			note "$dir" "$checkout_risk"
			continue
		fi
		add worktree worktree "$dir" "$checkout_common"
	done 3<"$work/worktree-candidates"
}

# Plans `git worktree prune` for repositories whose worktree entries point
# at directories gone for AGE, or that will once planned deletions run.
# Prune cannot spare one entry, so a gone worktree whose detached HEAD no
# ref holds keeps all of its repository's entries.
plan_worktree_prunes() {
	local dir repo line id wt_head count held
	: >"$work/prune-repos.unsorted"
	: >"$work/affected-repos"
	[ "$have_git" -eq 1 ] || return 0
	while IFS= read -r dir <&3; do
		if [ -d "$dir/.git/worktrees" ]; then
			printf '%s\n' "$dir/.git" >>"$work/prune-repos.unsorted"
		fi
	done 3<"$work/checkouts"
	while IFS= read -r dir <&3; do
		[ -f "$dir/.git" ] || continue
		under_planned "$dir" || continue
		assess_cached "$dir"
		if [ "$checkout_linked" -eq 1 ] && [ -z "$checkout_risk" ]; then
			printf '%s\n' "$checkout_common" >>"$work/prune-repos.unsorted"
			printf '%s\n' "$checkout_common" >>"$work/affected-repos"
		fi
	done 3<"$contained"
	LC_ALL=C sort -u "$work/prune-repos.unsorted" >"$work/prune-repos"
	while IFS= read -r repo <&3; do
		safe_path "$repo" || continue
		if ! git_repo "$repo" worktree prune -n -v --expire="$git_expire" >"$work/prune-preview" 2>&1; then
			note "$repo" "git worktree prune --dry-run failed"
			continue
		fi
		count=0
		held=""
		while IFS= read -r line; do
			case "$line" in "Removing worktrees/"*) ;; *) continue ;; esac
			id="${line#Removing worktrees/}"
			id="${id%%:*}"
			count=$((count + 1))
			wt_head=""
			read -r wt_head <"$repo/worktrees/$id/HEAD" 2>/dev/null || true
			case "$wt_head" in
			"ref: "*) ;;
			*)
				if [ -z "$wt_head" ] || [ -z "$(git_repo "$repo" for-each-ref --count=1 --contains "$wt_head" --format=x refs/heads refs/remotes refs/tags 2>/dev/null || true)" ]; then
					held="$id"
				fi
				;;
			esac
		done <"$work/prune-preview"
		if [ -n "$held" ]; then
			note "$repo" "gone worktree $held holds commits no ref has; not pruning"
		elif [ "$count" -gt 0 ] || grep -Fxq -- "$repo" "$work/affected-repos"; then
			add prune worktree "$repo" "$count"
		fi
	done 3<"$work/prune-repos"
}

# Succeeds when LINK is a symlink that was not created or changed within
# AGE.
link_older() {
	[ -n "$(find "$1" -maxdepth 0 -type l ! -newermm "$cutoff" ! -newercm "$cutoff" -print 2>/dev/null)" ]
}

# link_older, for a symlink we own.
link_idle() {
	[ -n "$(find "$1" -maxdepth 0 -user "$uid" -print 2>/dev/null)" ] && link_older "$1"
}

# Nix out-links (result, result-*) and direnv layout dirs are GC roots.
# Idle ones go so that `nix-store --gc` can collect what they held. A
# dev shell stays while any process works in its project: a shell that
# loaded it days ago still runs its tools.
plan_nix_roots() {
	local path
	while IFS= read -r path <&3; do
		if link_idle "$path" && ! in_use "$path"; then
			add link nix "$path"
		fi
	done 3<"$work/outlinks"
	while IFS= read -r path <&3; do
		in_use "${path%/.direnv}" || plan_path nix "$path"
	done 3<"$work/direnvs"
}

# Prints, space-separated, the generations of PROFILE past the newest
# $keep_generations (the README's policy) that are older than AGE, never
# the current one.
old_generations() {
	local profile="$1" current link number rank=0
	current="$(readlink -- "$profile" 2>/dev/null || true)"
	current="${current##*/}"
	for link in "$profile"-*-link; do
		[ -L "$link" ] || continue
		number="${link##*/}"
		number="${number#"${profile##*/}"-}"
		number="${number%-link}"
		case "$number" in '' | *[!0-9]*) continue ;; esac
		printf '%s\t%s\n' "$number" "$link"
	done | LC_ALL=C sort -t "$tab" -k1,1nr | while IFS="$tab" read -r number link; do
		rank=$((rank + 1))
		if [ "$rank" -gt "$keep_generations" ] && [ "${link##*/}" != "$current" ] && link_older "$link"; then
			printf '%s\n' "$number"
		fi
	done | LC_ALL=C sort -n | awk '{ printf "%s%s", sep, $0; sep = " " } END { if (NR) print "" }'
}

# nix-env deletes our profiles' old generations; root's get a note.
plan_nix_generations() {
	local dir profile old
	command -v nix-env >/dev/null 2>&1 || return 0
	for dir in "${XDG_STATE_HOME:-$home/.local/state}/nix/profiles" "/nix/var/nix/profiles/per-user/$(id -un)" /nix/var/nix/profiles; do
		[ -d "$dir" ] || continue
		for profile in "$dir"/*; do
			[ -L "$profile" ] || continue
			case "$profile" in *-link) continue ;; esac
			safe_path "$profile" || continue
			old="$(old_generations "$profile")"
			[ -n "$old" ] || continue
			if [ -n "$(find "$profile" -maxdepth 0 -user "$uid" -print 2>/dev/null)" ]; then
				add generations nix "$profile" "$old"
			else
				note "$profile" "generations $old are idle; as root: nix-env --profile $profile --delete-generations $old"
			fi
		done
	done
}

# Prints the toolchain a rust-toolchain file selects, if it names one.
pin_channel() {
	awk '
		/^[[:space:]]*channel[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*["\047]/, "", line)
			sub(/["\047].*$/, "", line)
			print line
			found = 1
			exit
		}
		NF && first == "" { first = $1 }
		# Legacy rust-toolchain files may hold just the name.
		END { if (!found && first != "" && first !~ /[=\[]/) print first }
	' "$1" 2>/dev/null || true
}

# Succeeds for channels that name one release: 1.85, 1.85.0, or a dated
# beta or nightly.
versioned_channel() {
	case "$1" in
	nightly-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] | beta-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
	*[!0-9.]* | .* | *. | *..*) return 1 ;;
	*.*) return 0 ;;
	esac
	return 1
}

# Succeeds when the search covered all of HOME.
searched_home() {
	local root
	for root in "${search_roots[@]}"; do
		case "$root" in
		/) return 0 ;;
		"$home") return 0 ;;
		esac
		case "$home/" in "$root"/*) return 0 ;; esac
	done
	return 1
}

# Uninstalls idle versioned toolchains (1.85.0, nightly-2026-04-15, ...)
# that no default, override, rust-toolchain file, or dylint driver
# selects. Undated channels (stable, beta, nightly) stay, since `cargo
# +nightly` uses them without a pin. Pins are known only when the search
# covered HOME, and pins inside directories this run deletes do not count.
plan_rustup_toolchains() {
	local host pin channel dir name
	command -v rustup >/dev/null 2>&1 || return 0
	[ -d "$rustup_home/toolchains" ] || return 0
	if ! searched_home; then
		note "$rustup_home/toolchains" "not pruned: rust-toolchain pins are only known when searching $home"
		return 0
	fi
	host="$(cd / && RUSTUP_AUTO_INSTALL=0 rustup show 2>/dev/null | sed -n 's/^Default host: //p' || true)"
	[ -n "$host" ] || return 0
	{
		(cd / && RUSTUP_AUTO_INSTALL=0 rustup default 2>/dev/null | awk '{ print $1 }') || true
		(cd / && rustup override list 2>/dev/null | awk '{ print $NF }') || true
		# cargo-dylint builds one driver per toolchain it lints with.
		for dir in "${DYLINT_DRIVER_PATH:-$home/.dylint_drivers}"/*; do
			if [ -d "$dir" ]; then
				printf '%s\n' "${dir##*/}"
			fi
		done
		while IFS= read -r pin <&3; do
			if under_planned "$pin"; then
				continue
			fi
			channel="$(pin_channel "$pin")"
			case "$channel" in
			"") ;;
			*-"$host") printf '%s\n' "$channel" ;;
			*) printf '%s\n' "$channel-$host" ;;
			esac
		done 3<"$work/pins"
	} >"$work/selected-toolchains"
	for dir in "$rustup_home/toolchains"/*; do
		[ -d "$dir" ] && [ ! -L "$dir" ] || continue
		name="${dir##*/}"
		safe_path "$name" || continue
		case "$name" in *-"$host") ;; *) continue ;; esac
		versioned_channel "${name%-"$host"}" || continue
		if grep -Fxq -- "$name" "$work/selected-toolchains"; then
			continue
		fi
		if plannable "$dir"; then
			add toolchain toolchain "$dir" "$name"
		fi
	done
}

# Other tools' garbage collectors; they run after every deletion above.
# Container runtimes lose only images and build cache: a stopped
# container's writable layer can hold state, and `until` would judge it
# by when it was created, not when it stopped.
plan_collectors() {
	local tool
	for tool in docker podman; do
		command -v "$tool" >/dev/null 2>&1 || continue
		if ! "$tool" info >/dev/null 2>&1; then
			note "$tool" "not reachable; skipped its prune"
			continue
		fi
		add images gc "$tool"
		if [ "$tool" = docker ]; then
			add buildcache gc docker
		fi
	done
	if command -v flatpak >/dev/null 2>&1; then
		add flatpak gc flatpak
	fi
	if [ "$os" = Darwin ] && xcrun --find simctl >/dev/null 2>&1; then
		add simctl gc simctl
	fi
	if command -v nix-store >/dev/null 2>&1; then
		add nix-gc gc nix-store
	fi
}

# Drops repeated entries and entries inside another planned directory:
# deleting the parent covers them.
dedupe_plan() {
	awk -F '\t' '
		NR == FNR { if ($1 == "path" || $1 == "worktree") planned[$3] = 1; next }
		seen[$1 "\t" $3]++ { next }
		{
			p = $3
			while (sub(/\/[^\/]*$/, "", p) && p != "")
				if (p in planned) next
			print
		}' "$plan" "$plan" >"$plan.deduped"
	mv "$plan.deduped" "$plan"
}

# awk function behind every size printout; sizes are in KiB.
readonly awk_human='
function human(kb,    i, unit) {
	split("K M G T", unit, " ")
	for (i = 1; kb >= 1024 && i < 4; i++) kb /= 1024
	return sprintf(i == 1 ? "%d%s" : "%.1f%s", kb, unit[i])
}'

human_kb() {
	awk -v kb="$1" "$awk_human"' BEGIN { print human(kb) }'
}

# Records sizes, measuring up to $parallel_jobs trees at a time; drops
# paths that occupy no blocks, since deleting them frees nothing. Links
# and commands free space only through a collector.
size_plan() {
	local method label path arg
	while IFS="$tab" read -r method label path arg; do
		case "$method" in path | worktree | toolchain) printf '%s\0' "$path" ;; esac
	done <"$plan" | parallel_runs 1 'du -skx -- "$@" 2>/dev/null' >"$work/sizes"
	awk -F '\t' '
		FILENAME == ARGV[1] { kb[substr($0, index($0, "\t") + 1)] = $1; next }
		{
			size = ($1 == "path" || $1 == "worktree" || $1 == "toolchain") ? kb[$3] + 0 : 0
			if ($1 == "path" && size == 0) next
			print size "\t" $0
		}' "$work/sizes" "$plan" >"$work/sized"
}

readonly sections="rust build-cache cache tmp xcode agent worktree nix toolchain gc"

label_title() {
	case "$1" in
	rust) echo "Rust build artifacts" ;;
	build-cache) echo "Build caches" ;;
	cache) echo "Caches" ;;
	tmp) echo "Temporary files" ;;
	xcode) echo "Xcode DerivedData" ;;
	agent) echo "Orphaned omp task copies" ;;
	worktree) echo "Git worktrees" ;;
	nix) echo "Nix roots and generations" ;;
	toolchain) echo "Rust toolchains" ;;
	gc) echo "Garbage collectors" ;;
	esac
}

# Prints each section largest first. A parent with more than five planned
# paths shows its four largest and one line for the rest.
print_plan() {
	local label
	for label in $sections; do
		awk -F '\t' -v label="$label" '$3 == label' "$work/sized" | LC_ALL=C sort -t "$tab" -k1,1nr >"$work/section"
		[ -s "$work/section" ] || continue
		printf '%s\n' "$(label_title "$label")"
		awk -F '\t' -v age_m="$age_minutes" '
			function show(method, path, arg) {
				if (method == "worktree") return path " (git worktree remove)"
				if (method == "prune") return path (arg > 0 ? ": prune " arg " stale worktree entries" : ": prune worktree entries after deletions")
				if (method == "link") return path " (nix out-link)"
				if (method == "generations") return path ": delete generations " arg
				if (method == "toolchain") return "rustup toolchain uninstall " arg
				if (method == "images") return path " image prune --all --filter until=" age_m "m"
				if (method == "buildcache") return path " builder prune --filter until=" age_m "m"
				if (method == "flatpak") return "flatpak uninstall --user --unused"
				if (method == "simctl") return "xcrun simctl delete unavailable"
				if (method == "nix-gc") return "nix-store --gc"
				return path
			}
			{ parent = $4; sub(/\/[^\/]*$/, "", parent) }
			NR == FNR { if ($2 == "path") count[parent]++; next }
			$2 == "path" && count[parent] > 5 && ++shown[parent] > 4 { rest[parent] += $1; next }
			{ print $1 "\t" show($2, $4, $5) }
			END { for (p in rest) print rest[p] "\t" p "/ (+" count[p] - 4 " more)" }
		' "$work/section" "$work/section" | LC_ALL=C sort -t "$tab" -k1,1nr |
			awk -F '\t' "$awk_human"' { printf "  %8s  %s\n", human($1), $2 }'
	done
}

print_notes() {
	[ -s "$notes" ] || return 0
	printf 'Kept or skipped\n'
	LC_ALL=C sort -u "$notes" | awk -F '\t' '{ printf "  %s: %s\n", $1, $2 }'
}

free_kb() {
	df -Pk "$home" | awk 'NR == 2 { print $4 }'
}

delete_path() {
	if rm -rf "$rm_one_fs" -- "$1" 2>/dev/null; then
		return 0
	fi
	# Read-only trees (Go modules, copies of store paths) need write access.
	chmod -R u+w -- "$1" 2>/dev/null || true
	rm -rf "$rm_one_fs" -- "$1"
}

failures=0
done_items=0
deleted_kb=0

finished() {
	done_items=$((done_items + 1))
	deleted_kb=$((deleted_kb + $1))
}

failed() {
	warn "$*"
	failures=$((failures + 1))
}

# Succeeds when a planned row still qualifies; anything touched, opened,
# or changed in git while the plan waited for confirmation stays.
still_planned() {
	local method="$1" path="$2"
	case "$method" in
	path | worktree | toolchain)
		[ -e "$path" ] || return 1
		if ! plannable "$path"; then
			printf 'kept (used since planning): %s\n' "$path"
			return 1
		fi
		if [ "$method" = worktree ]; then
			assess_checkout "$path"
			if [ -n "$checkout_risk" ] || ! ignored_regenerable "$path"; then
				printf 'kept (changed since planning): %s\n' "$path"
				return 1
			fi
		fi
		;;
	link)
		[ -L "$path" ] || return 1
		if ! link_idle "$path" || in_use "$path"; then
			printf 'kept (changed since planning): %s\n' "$path"
			return 1
		fi
		;;
	esac
}

run_row() {
	local method="$1" path="$2" arg="$3"
	case "$method" in
	path) delete_path "$path" ;;
	link) rm -f -- "$path" ;;
	worktree) git_repo "$arg" worktree remove "$path" ;;
	toolchain) rustup toolchain uninstall "$arg" ;;
	prune)
		printf 'pruning worktree entries in %s\n' "$path"
		git_repo "$path" worktree prune -v --expire="$git_expire" 2>&1
		;;
	generations)
		# shellcheck disable=SC2086 # one argument per generation number
		nix-env --profile "$path" --delete-generations $arg
		;;
	images) "$path" image prune --all --force --filter "until=${age_minutes}m" ;;
	buildcache) "$path" builder prune --force --filter "until=${age_minutes}m" ;;
	flatpak) flatpak uninstall --user --unused -y ;;
	simctl) xcrun simctl delete unavailable ;;
	nix-gc) nix-store --gc ;;
	*) return 1 ;;
	esac
}

# Runs the planned rows whose method is one of the arguments.
run_rows() {
	local kb method label path arg
	while IFS="$tab" read -r kb method label path arg <&3; do
		case " $* " in *" $method "*) ;; *) continue ;; esac
		still_planned "$method" "$path" || continue
		if run_row "$method" "$path" "$arg"; then
			finished "$kb"
		else
			failed "$method failed: $path"
		fi
	done 3<"$work/sized"
}

# Deletions first; prunes then cover worktrees deleted with their
# directory, and collectors run last to reclaim what the deletions
# released.
execute_plan() {
	snapshot_open_paths
	reads_after="$plan_done"
	reads_before=""
	assessed=()
	assessed_risk=()
	assessed_linked=()
	assessed_common=()
	plannable_yes="$nl"
	plannable_no="$nl"
	run_rows path worktree link toolchain
	run_rows prune
	run_rows generations
	run_rows images buildcache flatpak simctl
	run_rows nix-gc
}

main() {
	printf 'clean-stale: looking for files idle for %s (untouched since %s)\n' \
		"$age" "$(date_at "$cutoff_epoch" '+%Y-%m-%d %H:%M')"

	section "scanning ${search_roots[*]}${temp_roots[*]:+ ${temp_roots[*]}}"
	snapshot_open_paths
	discover | classify_discoveries
	find_contained_checkouts
	plan_rust_targets
	plan_build_caches
	if [ "$os" = Darwin ]; then
		plan_cache_root "$home/Library/Caches"
	fi
	plan_cache_root "$cache_home"
	plan_package_caches
	plan_temp
	plan_entries xcode "$home/Library/Developer/Xcode/DerivedData"
	plan_omp_isolation
	plan_worktrees
	plan_worktree_prunes
	plan_nix_roots
	plan_nix_generations
	plan_rustup_toolchains
	plan_collectors
	dedupe_plan
	size_plan
	# Round up so our last planning reads fall before the mark.
	set_mtime "$(($(current_epoch) + 1))" "$plan_done"

	local count total_kb
	count="$(awk 'END { print NR }' "$work/sized")"
	total_kb="$(awk -F '\t' '{ s += $1 } END { print s + 0 }' "$work/sized")"
	if [ "$count" -eq 0 ]; then
		section "nothing idle for $age"
		print_notes
		return 0
	fi
	section "plan: $count items, $(human_kb "$total_kb")"
	print_plan
	print_notes

	if [ "$dry_run" -eq 1 ]; then
		printf '\ndry run: nothing deleted\n'
		return 0
	fi
	if [ "$assume_yes" -ne 1 ]; then
		if [ ! -t 0 ]; then
			printf 'clean-stale: stdin is not a terminal; rerun with --yes to delete\n' >&2
			return 1
		fi
		local reply
		printf '\nDelete these %s items? [y/N] ' "$count"
		read -r reply || reply=""
		case "$reply" in
		y | Y | yes | YES) ;;
		*)
			printf 'nothing deleted\n'
			return 0
			;;
		esac
	fi

	local free_before
	free_before="$(free_kb)"
	section "deleting"
	execute_plan
	section "summary"
	printf 'done %s of %s items (%s); free space %s -> %s\n' \
		"$done_items" "$count" "$(human_kb "$deleted_kb")" \
		"$(human_kb "$free_before")" "$(human_kb "$(free_kb)")"
	if [ "$failures" -gt 0 ]; then
		printf 'failures: %s\n' "$failures"
		return 1
	fi
}

main
