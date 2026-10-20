#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/clean-stale.sh"
nl=$'\n'

fixture="$(mktemp -d)"
fixture="$(cd -P "$fixture" && pwd)"
busy_pid=""
cleanup() {
	if [ -n "$busy_pid" ]; then
		kill "$busy_pid" 2>/dev/null || true
		wait "$busy_pid" 2>/dev/null || true
	fi
	chmod -R u+w "$fixture" 2>/dev/null || true
	rm -rf "$fixture"
}
trap cleanup EXIT

# Only these tools are visible, so no run can reach the real nix, docker,
# cargo, or rustup.
bin="$fixture/bin"
mkdir -p "$bin"
for tool in awk basename bash cat chmod date df du find getconf git grep head id ln lsof mkdir mkfifo mktemp mv ps readlink rm sed sleep sort stat touch tr uname; do
	path="$(command -v "$tool" 2>/dev/null || true)"
	if [ -z "$path" ] && [ -x "/usr/sbin/$tool" ]; then
		path="/usr/sbin/$tool"
	fi
	if [ -n "$path" ]; then
		ln -s "$path" "$bin/$tool"
	fi
done
export PATH="$bin"

export HOME="$fixture/home"
tmp="$fixture/tmp"
mkdir -p "$HOME" "$tmp"
unset XDG_CACHE_HOME CARGO_HOME RUSTUP_HOME GOPATH GOMODCACHE
export CLEAN_STALE_TEMP_ROOTS="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

if date --version >/dev/null 2>&1; then
	stamp() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
else
	stamp() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
fi
# Four days from now, everything created below has been idle for days.
CLEAN_STALE_NOW=$(($(date +%s) + 4 * 86400))
export CLEAN_STALE_NOW

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# 8 KiB occupies blocks everywhere; tiny files can be inlined and count as 0K.
file() {
	mkdir -p "${1%/*}"
	printf '%8192s' x >"$1"
}

# Marks files as written an hour before the fake clock.
touch_recent() {
	touch -m -d "$(stamp $((CLEAN_STALE_NOW - 3600)))" "$@"
}

cache_tag() {
	mkdir -p "$1"
	printf 'Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by %s.\n' "$2" >"$1/CACHEDIR.TAG"
}

cargo_target() {
	cache_tag "$1" cargo
	printf '{}\n' >"$1/.rustc_info.json"
}

src="$HOME/src"
cargo_target "$src/app/target"
file "$src/app/target/debug/deps/libapp.rlib"
touch_recent "$src/app/target/debug/deps/libapp.rlib"
file "$src/app/target/release/deps/libapp.rlib"
file "$src/app/target/notes.json"
cargo_target "$src/app/target/wt-old"
file "$src/app/target/wt-old/debug/app"
cargo_target "$src/app/target/wt-busy"
file "$src/app/target/wt-busy/debug/app"
file "$src/app/target/wt-busy/release/app"
touch_recent "$src/app/target/wt-busy/release/app"
cargo_target "$src/old/target"
file "$src/old/target/debug/app"
cache_tag "$src/app/.pytest_cache" pytest
file "$src/app/.pytest_cache/v/cache/lastfailed"
mkdir -p "$src/app/.venv"
printf 'Signature: 8a477f597d28d172789f06886806bc55' >"$src/app/.venv/CACHEDIR.TAG"
file "$src/app/.venv/pyvenv.cfg"
file "$src/app/.venv/lib/site.py"
cache_tag "$src/vendored/vendor/crate/docs" cargo
file "$src/vendored/vendor/crate/docs/index.html"
cache_tag "$HOME/.cargo/registry" cargo
file "$HOME/.cargo/registry/cache/crate.crate"

file "$HOME/.cache/stale-app/data"
file "$HOME/.cache/fresh-app/data"
touch_recent "$HOME/.cache/fresh-app/data"
file "$HOME/.cache/huggingface/hub/model"
mkdir -p "$HOME/.cache/empty-app"
file "$HOME/.cache/nix/eval-cache-v6/old.sqlite"
file "$HOME/.cache/nix/eval-cache-v6/new.sqlite"
touch_recent "$HOME/.cache/nix/eval-cache-v6/new.sqlite"
file "$HOME/.cache/nix/tarball-cache/HEAD"
file "$fixture/precious/data"
ln -s "$fixture/precious" "$HOME/.cache/linked"
file "$HOME/.npm/_cacache/index-v5/entry"
if [ "$(uname -s)" = Darwin ]; then
	file "$HOME/Library/Caches/old-app/data"
	file "$HOME/Library/Caches/com.apple.Safari/data"
fi

file "$tmp/old-build/out"
file "$tmp/.hidden/state"
file "$tmp/pipe/data"
mkfifo "$tmp/pipe/fifo"
: >"$tmp/empty.log"
file "$tmp/busy/data"
(cd "$tmp/busy" && exec sleep 300) &
busy_pid=$!

# Git: "origin" holds pushed history, so clones of it hold no unique work.
origin="$fixture/origin.git"
git init -q -b main "$src/proj"
printf 'target/\n.env\n' >"$src/proj/.gitignore"
git -C "$src/proj" add .gitignore
git -C "$src/proj" commit -qm init
git clone -q --bare "$src/proj" "$origin"
git -C "$src/proj" remote add origin "$origin"
git -C "$src/proj" fetch -q origin

worktree() {
	git -C "$src/proj" worktree add -q "$@"
}
worktree -b feature "$src/wt-clean"
cargo_target "$src/wt-clean/target"
file "$src/wt-clean/target/debug/app"
worktree -b dirty "$src/wt-dirty"
file "$src/wt-dirty/notes.txt"
worktree --detach "$src/wt-detached"
git -C "$src/wt-detached" commit -q --allow-empty -m "only here"
worktree -b envwt "$src/wt-env"
file "$src/wt-env/.env"
worktree -b locked "$src/wt-locked"
git -C "$src/proj" worktree lock "$src/wt-locked"
worktree -b gone "$src/wt-gone"
rm -rf "$src/wt-gone"
worktree -b scratch "$tmp/scratch/proj"

# A task dir in an idle target holds a probe repository with local-only
# commits and a nested target dir. Planning around the probe reaches the
# nested target, and so does the nested target's own pass.
cargo_target "$src/old2/target"
file "$src/old2/target/debug/app"
git init -q -b main "$src/old2/target/task/probe"
file "$src/old2/target/task/probe/a.txt"
git -C "$src/old2/target/task/probe" add a.txt
git -C "$src/old2/target/task/probe" commit -qm probe
cargo_target "$src/old2/target/task/build"
file "$src/old2/target/task/build/debug/app"
# A clean clone (as cargo-dylint makes) does not protect its target dir.
cargo_target "$src/old3/target"
file "$src/old3/target/debug/app"
git clone -q "$origin" "$src/old3/target/dylint/clone"
git clone -q "$origin" "$tmp/dirty-clone"
file "$tmp/dirty-clone/wip.txt"

# omp task copies, each with an owner record.
(exit 0) &
dead_pid=$!
wait "$dead_pid"
live_start="$(ps -o lstart= -p $$)"
omp_copy() {
	git clone -q "$origin" "$1/m"
	printf '{"pid":%s,"id":"task","startToken":"%s"}' "$2" "$3" >"$1/.omp-isolation-owner.json"
}
omp_copy "$HOME/.omp/wt/dead" "$dead_pid" "$live_start"
omp_copy "$HOME/.omp/wt/live" $$ "$live_start"
omp_copy "$HOME/.omp/wt/reused" $$ "Thu Jan  1 00:00:00 1970"
omp_copy "$HOME/.omp/wt/dirty" "$dead_pid" "$live_start"
file "$HOME/.omp/wt/dirty/m/wip.txt"

run() {
	bash "$script" "$@"
}

assert_gone() {
	local path
	for path in "$@"; do
		if [ -e "$path" ] || [ -L "$path" ]; then
			fail "expected deleted: $path"
		fi
	done
}

assert_kept() {
	local path
	for path in "$@"; do
		if [ ! -e "$path" ] && [ ! -L "$path" ]; then
			fail "expected kept: $path"
		fi
	done
}

expected_gone=(
	"$src/app/target/release"
	"$src/app/target/notes.json"
	"$src/app/target/wt-old"
	"$src/app/target/wt-busy/debug"
	"$src/old/target"
	"$src/old2/target/debug"
	"$src/old2/target/task/build"
	"$src/old3/target"
	"$src/app/.pytest_cache"
	"$src/wt-clean"
	"$HOME/.cache/stale-app"
	"$HOME/.cache/nix/eval-cache-v6/old.sqlite"
	"$HOME/.cache/nix/tarball-cache"
	"$HOME/.npm/_cacache"
	"$HOME/.omp/wt/dead"
	"$HOME/.omp/wt/reused"
	"$tmp/old-build"
	"$tmp/scratch"
)
expected_kept=(
	"$src/app/target/CACHEDIR.TAG"
	"$src/app/target/debug/deps/libapp.rlib"
	"$src/app/target/wt-busy/release/app"
	"$src/app/.venv/lib/site.py"
	"$src/vendored/vendor/crate/docs/index.html"
	"$HOME/.cargo/registry/cache/crate.crate"
	"$HOME/.cache/fresh-app/data"
	"$HOME/.cache/huggingface/hub/model"
	"$HOME/.cache/empty-app"
	"$HOME/.cache/nix/eval-cache-v6/new.sqlite"
	"$HOME/.cache/linked"
	"$fixture/precious/data"
	"$tmp/.hidden/state"
	"$tmp/pipe/data"
	"$tmp/empty.log"
	"$tmp/dirty-clone/wip.txt"
	"$src/old2/target/task/probe/a.txt"
	"$src/wt-dirty/notes.txt"
	"$src/wt-detached"
	"$src/wt-env/.env"
	"$src/wt-locked"
	"$HOME/.omp/wt/live/m"
	"$HOME/.omp/wt/dirty/m/wip.txt"
)
expected_notes=(
	"$src/wt-dirty: uncommitted changes"
	"$src/wt-detached: HEAD is on no branch, tag, or remote"
	"$src/wt-env: ignored .env may not be regenerable"
	"$src/wt-locked: locked worktree"
	"$src/old2/target/task/probe: commits no remote or tag holds"
	"$tmp/dirty-clone: uncommitted changes"
	"$HOME/.omp/wt/dirty/m: uncommitted changes (orphaned omp task copy)"
)
if [ "$(uname -s)" = Darwin ]; then
	expected_gone+=("$HOME/Library/Caches/old-app")
	expected_kept+=("$HOME/Library/Caches/com.apple.Safari/data")
fi
if [ -e "$bin/lsof" ] || [ -d /proc/self/fd ]; then
	expected_kept+=("$tmp/busy/data")
fi

for bad_age in 0 5x 1w 1234567h; do
	set +e
	run --age "$bad_age" --dry-run >/dev/null 2>&1
	status=$?
	set -e
	[ "$status" -eq 2 ] || fail "--age $bad_age: expected status 2, got $status"
done

# Nothing in the fixture is 200 hours old yet.
output="$(run --age 200h --dry-run)"
case "$output" in *"nothing idle for 200h"*) ;; *) fail "200h threshold planned deletions: $output" ;; esac

# Paths the plan lists for deletion, without their sizes.
planned() {
	printf '%s\n' "$output" | awk '/^  / { sub(/^ +[^ ]+  /, ""); sub(/ \(git worktree remove\)$/, ""); print }'
}

output="$(run --dry-run)"
for path in "${expected_gone[@]}"; do
	planned | grep -Fxq -- "$path" || fail "dry run does not list $path${nl}$output"
done
for path in "${expected_kept[@]}"; do
	if planned | grep -Fxq -- "$path"; then
		fail "dry run lists kept path $path"
	fi
done
duplicate="$(planned | awk 'seen[$0]++ { print; exit }')"
[ -z "$duplicate" ] || fail "dry run lists $duplicate twice"
for line in "${expected_notes[@]}"; do
	case "$output" in *"  $line$nl"* | *"  $line") ;; *) fail "dry run does not report kept $line${nl}$output" ;; esac
done
case "$output" in *"$src/proj/.git: prune 1 stale worktree entries"*) ;; *) fail "dry run does not prune the gone worktree${nl}$output" ;; esac
assert_kept "${expected_gone[@]}" "${expected_kept[@]}"

set +e
run </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "non-interactive run without --yes: expected status 1, got $status"
assert_kept "${expected_gone[@]}"

if ! output="$(run --yes 2>&1)"; then
	fail "run --yes failed:$nl$output"
fi
assert_gone "${expected_gone[@]}"
assert_kept "${expected_kept[@]}"

# Removal kept the branches, pruned entries for gone directories, and left
# every protected worktree registered.
for branch in feature scratch gone; do
	git -C "$src/proj" rev-parse -q --verify "refs/heads/$branch" >/dev/null || fail "branch $branch was deleted"
done
registered="$(git -C "$src/proj" worktree list --porcelain | sed -n 's/^worktree //p')"
for path in "$src/wt-clean" "$src/wt-gone" "$tmp/scratch/proj"; do
	case "$nl$registered$nl" in *"$nl$path$nl"*) fail "worktree $path is still registered" ;; esac
done
for path in "$src/wt-dirty" "$src/wt-detached" "$src/wt-env" "$src/wt-locked"; do
	case "$nl$registered$nl" in *"$nl$path$nl"*) ;; *) fail "worktree $path was unregistered" ;; esac
done

# A second run finds nothing new.
output="$(run --dry-run)"
case "$output" in *"nothing idle for 36h"*) ;; *) fail "second run planned deletions: $output" ;; esac
