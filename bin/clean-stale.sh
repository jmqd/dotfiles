#!/usr/bin/env bash
# Deletes regenerable files that nothing has touched for a while. Runs on
# macOS and Linux with bash 3.2+ and either GNU or BSD userland tools.
set -euo pipefail

readonly default_age=36h
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

Keeps anything written, renamed, read (where the filesystem records
reads), or held open by a process within AGE; anything containing a
socket or FIFO; empty files and directories; and caches that hold
installs or models (playwright, puppeteer, huggingface, ...).

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

device_of() {
	if [ "$gnu_stat" -eq 1 ]; then
		stat -c %d -- "$1"
	else
		stat -f %d -- "$1"
	fi
}

work="$(mktemp -d "${TMPDIR:-/tmp}/clean-stale.XXXXXX")"
trap 'rm -rf "$work"' EXIT
plan="$work/plan"
planned_dirs="$work/planned-dirs"
open_paths="$work/open-paths"
: >"$plan"
: >"$planned_dirs"

# CLEAN_STALE_NOW (epoch seconds) moves the clock for tests.
now="${CLEAN_STALE_NOW:-$(date +%s)}"
case "$now" in '' | *[!0-9]*) die "CLEAN_STALE_NOW must be epoch seconds" ;; esac
cutoff_epoch=$((now - age_minutes * 60))
cutoff="$work/cutoff"
touch -d "$(date_at "$cutoff_epoch" -u +%Y-%m-%dT%H:%M:%SZ)" "$cutoff"

# Succeeds when nothing at or below PATH was modified, changed, or (files
# only; our own scans read directories) accessed after the cutoff, and no
# socket or FIFO lives there. A tree we cannot fully read counts as busy.
is_idle() {
	local hit
	hit="$(find "$1" -xdev \( -type s -o -type p -o -newermm "$cutoff" -o -newercm "$cutoff" -o \( ! -type d -neweram "$cutoff" \) \) -print -quit 2>/dev/null)" || return 1
	[ -z "$hit" ]
}

# Lists every path our processes hold open or work in, plus all parents,
# so a directory is in use exactly when its path appears.
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
	} | awk '{ p = $0; while (p != "" && p != "/") { print p; sub(/\/[^\/]*$/, "", p) } }' |
		LC_ALL=C sort -u >"$open_paths"
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
plannable() {
	local path="$1"
	[ ! -L "$path" ] || return 1
	if [ -d "$path" ]; then
		[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || return 1
		[ "$(device_of "$path")" = "$(device_of "${path%/*}")" ] || return 1
	elif [ -f "$path" ]; then
		[ -s "$path" ] || return 1
	else
		return 1
	fi
	[ -O "$path" ] || return 1
	! in_use "$path" || return 1
	is_idle "$path"
}

add() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$plan"
	if [ "$1" = path ]; then
		printf '%s\n' "$3" >>"$planned_dirs"
	fi
}

plan_path() {
	if plannable "$2"; then
		add path "$1" "$2"
	fi
}

under_planned() {
	local parent="$1"
	while parent="${parent%/*}" && [ -n "$parent" ]; do
		if grep -Fxq -- "$parent" "$planned_dirs"; then
			return 0
		fi
	done
	return 1
}

children() {
	find "$1" -mindepth 1 -maxdepth 1 "${@:2}" -print0 2>/dev/null
}

# Plans each idle entry directly inside DIR.
plan_entries() {
	local label="$1" dir="$2" entry
	[ -d "$dir" ] && [ ! -L "$dir" ] || return 0
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		plan_path "$label" "$entry"
	done < <(children "$dir")
}

# Prints, NUL-separated, every CACHEDIR.TAG, .git, and rust-toolchain file
# under the search and temp roots. Trees that cannot hold projects are pruned.
discover() {
	local prune=(
		-name .direnv -o -name node_modules -o
		-name deps -o -name .fingerprint -o -name incremental -o
		-path "$home/Library" -o -path "$home/.Trash" -o -path "$home/.local/share/Trash" -o
		-path "$home/Pictures" -o -path "$home/Music" -o -path "$home/Movies" -o
		-path "$cache_home" -o -path "$cargo_home" -o -path "$rustup_home" -o
		-path "$home/.npm" -o -path "$home/.nix-defexpr"
	)
	find "${search_roots[@]}" ${temp_roots[@]+"${temp_roots[@]}"} -xdev \
		\( -name .git -type d -print0 -prune \) -o \
		\( \( "${prune[@]}" \) -prune \) -o \
		\( -type f \( -name CACHEDIR.TAG -o -name .git -o -name rust-toolchain -o -name rust-toolchain.toml \) -print0 \) \
		2>/dev/null || true
}

# Splits discoveries into cargo target dirs (cargo's tag plus
# .rustc_info.json; vendored crates and CARGO_HOME carry only the tag),
# other tagged caches, git checkouts, and toolchain pins.
classify_discoveries() {
	local path dir
	: >"$work/rust-targets.unsorted"
	: >"$work/build-caches.unsorted"
	: >"$work/checkouts.unsorted"
	: >"$work/pins.unsorted"
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
		*) printf '%s\n' "$path" >>"$work/pins.unsorted" ;;
		esac
	done
	local list
	for list in rust-targets build-caches checkouts pins; do
		LC_ALL=C sort -u "$work/$list.unsorted" >"$work/$list"
	done
}

# Plans an idle target dir whole; otherwise plans its idle profiles, task
# dirs, and loose files. Nested target dirs get their own pass.
# shellcheck disable=SC2094 # the loop and the nested check only read the list
plan_rust_targets() {
	local target entry
	while IFS= read -r target <&3; do
		if under_planned "$target"; then
			continue
		fi
		if plannable "$target"; then
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
	while IFS= read -r dir <&3; do
		plan_path build-cache "$dir"
	done 3<"$work/build-caches"
}

# Nix keeps one eval cache per flake revision, so idle ones go even while
# the directory stays busy.
plan_nix_cache() {
	local entry
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		if plannable "$entry"; then
			add path cache "$entry"
		elif [ -d "$entry" ] && [ ! -L "$entry" ]; then
			case "${entry##*/}" in eval-cache-v*) plan_entries cache "$entry" ;; esac
		fi
	done < <(children "$1")
}

plan_cache_root() {
	local entry
	[ -d "$1" ] || return 0
	while IFS= read -r -d '' entry; do
		safe_path "$entry" || continue
		case "${entry##*/}" in
		# macOS system state rather than app caches.
		com.apple.* | CloudKit | FamilyCircle | GeoServices | PassKit | Metadata | familycircled) continue ;;
		# Installs and models that tools do not fetch again on demand.
		ms-playwright* | puppeteer | Cypress | huggingface | torch | whisper | lm-studio | llama.cpp | gpt4all | codex-runtimes | pypoetry) continue ;;
		nix)
			plan_nix_cache "$entry"
			continue
			;;
		esac
		plan_path cache "$entry"
	done < <(children "$1")
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
}

# Only our own entries; dot-entries and Apple's per-daemon dirs belong to
# running services.
plan_temp() {
	local dir entry
	for dir in ${temp_roots[@]+"${temp_roots[@]}"}; do
		while IFS= read -r -d '' entry; do
			safe_path "$entry" || continue
			case "${entry##*/}" in .* | com.apple.* | TemporaryItems) continue ;; esac
			plan_path tmp "$entry"
		done < <(children "$dir" -user "$uid")
	done
}

# Drops entries inside another planned directory: deleting the parent
# covers them.
dedupe_plan() {
	awk -F '\t' '
		NR == FNR { if ($1 == "path") planned[$3] = 1; next }
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

# Records sizes; drops paths that occupy no blocks, since deleting them
# frees nothing.
size_plan() {
	local method label path arg kb
	while IFS="$tab" read -r method label path arg <&3; do
		kb="$({ du -skx -- "$path" 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
		kb="${kb:-0}"
		if [ "$method" = path ] && [ "$kb" -eq 0 ]; then
			continue
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$kb" "$method" "$label" "$path" "$arg"
	done 3<"$plan" >"$work/sized"
}

label_title() {
	case "$1" in
	rust) echo "Rust build artifacts" ;;
	build-cache) echo "Build caches" ;;
	cache) echo "Caches" ;;
	tmp) echo "Temporary files" ;;
	xcode) echo "Xcode DerivedData" ;;
	esac
}

# Prints each section largest first. A parent with more than five planned
# entries shows its four largest and one line for the rest.
print_plan() {
	local label
	for label in rust build-cache cache tmp xcode; do
		awk -F '\t' -v label="$label" '$3 == label' "$work/sized" | LC_ALL=C sort -t "$tab" -k1,1nr >"$work/section"
		[ -s "$work/section" ] || continue
		printf '%s\n' "$(label_title "$label")"
		awk -F '\t' '
			{ parent = $4; sub(/\/[^\/]*$/, "", parent) }
			NR == FNR { count[parent]++; next }
			count[parent] > 5 && ++shown[parent] > 4 { rest[parent] += $1; next }
			{ print $1 "\t" $4 }
			END { for (p in rest) print rest[p] "\t" p "/ (+" count[p] - 4 " more)" }
		' "$work/section" "$work/section" | LC_ALL=C sort -t "$tab" -k1,1nr |
			awk -F '\t' "$awk_human"' { printf "  %8s  %s\n", human($1), $2 }'
	done
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
deleted=0
deleted_kb=0

# Re-checks every entry against fresh state: anything touched or opened
# while the plan waited for confirmation stays.
execute_plan() {
	local kb method label path arg
	snapshot_open_paths
	while IFS="$tab" read -r kb method label path arg <&3; do
		[ -e "$path" ] || [ -L "$path" ] || continue
		if ! plannable "$path"; then
			printf 'kept (busy since planning): %s\n' "$path"
			continue
		fi
		if delete_path "$path"; then
			deleted=$((deleted + 1))
			deleted_kb=$((deleted_kb + kb))
		else
			warn "could not delete $path"
			failures=$((failures + 1))
		fi
	done 3<"$work/sized"
}

main() {
	printf 'clean-stale: looking for files idle for %s (untouched since %s)\n' \
		"$age" "$(date_at "$cutoff_epoch" '+%Y-%m-%d %H:%M')"

	section "scanning ${search_roots[*]}${temp_roots[*]:+ ${temp_roots[*]}}"
	snapshot_open_paths
	discover | classify_discoveries
	plan_rust_targets
	plan_build_caches
	if [ "$os" = Darwin ]; then
		plan_cache_root "$home/Library/Caches"
	fi
	plan_cache_root "$cache_home"
	plan_package_caches
	plan_temp
	plan_entries xcode "$home/Library/Developer/Xcode/DerivedData"
	dedupe_plan
	size_plan

	local count total_kb
	count="$(awk 'END { print NR }' "$work/sized")"
	total_kb="$(awk -F '\t' '{ s += $1 } END { print s + 0 }' "$work/sized")"
	if [ "$count" -eq 0 ]; then
		section "nothing idle for $age"
		return 0
	fi
	section "plan: $count items, $(human_kb "$total_kb")"
	print_plan

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
	printf 'deleted %s of %s items (%s); free space %s -> %s\n' \
		"$deleted" "$count" "$(human_kb "$deleted_kb")" \
		"$(human_kb "$free_before")" "$(human_kb "$(free_kb)")"
	if [ "$failures" -gt 0 ]; then
		printf 'failures: %s\n' "$failures"
		return 1
	fi
}

main
