#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/clean-stale.sh"
nl=$'\n'

fixture="$(mktemp -d)"
fixture="$(cd -P "$fixture" && pwd)"
busy_pids=()
cleanup() {
	local pid
	for pid in ${busy_pids[@]+"${busy_pids[@]}"}; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
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

# Logging stand-ins for the tools whose collectors clean-stale runs.
calls="$fixture/calls"
: >"$calls"
bash_path="$(command -v bash)"
cat >"$bin/nix-store" <<EOF
#!$bash_path
printf 'nix-store %s\n' "\$*" >>"$calls"
EOF
cat >"$bin/nix-env" <<EOF
#!$bash_path
printf 'nix-env %s\n' "\$*" >>"$calls"
[ "\$1" = --profile ] && [ "\$3" = --delete-generations ] || exit 64
profile="\$2"
shift 3
for generation in "\$@"; do
	rm -f "\$profile-\$generation-link"
done
EOF
cat >"$bin/rustup" <<EOF
#!$bash_path
case "\$*" in
show) printf 'Default host: test-host\n' ;;
default) printf 'stable-test-host (default)\n' ;;
"override list") printf 'no overrides\n' ;;
"toolchain uninstall "*)
	printf 'rustup %s\n' "\$*" >>"$calls"
	rm -rf "\$HOME/.rustup/toolchains/\$3"
	;;
*) exit 64 ;;
esac
EOF
cat >"$bin/docker" <<EOF
#!$bash_path
[ "\$1" = info ] && exit 0
printf 'docker %s\n' "\$*" >>"$calls"
EOF
chmod +x "$bin/nix-store" "$bin/nix-env" "$bin/rustup" "$bin/docker"

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
busy_pids+=($!)

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

# Nix: eight old profile generations, seven recent ones, out-links, and
# dev shells.
profiles="$HOME/.local/state/nix/profiles"
mkdir -p "$profiles"
for generation in 1 2 3 4 5 6 7 8; do
	ln -s "/nix/store/fake-profile-$generation" "$profiles/profile-$generation-link"
done
ln -s profile-8-link "$profiles/profile"
for generation in 1 2 3 4 5 6 7; do
	ln -s "/nix/store/fake-channels-$generation" "$profiles/channels-$generation-link"
	touch -h -m -d "$(stamp $((CLEAN_STALE_NOW - 3600)))" "$profiles/channels-$generation-link"
done
ln -s channels-7-link "$profiles/channels"
ln -s /nix/store/fake-proj "$src/proj/result"
ln -s /nix/store/fake-fresh "$src/proj/result-fresh"
touch -h -m -d "$(stamp $((CLEAN_STALE_NOW - 3600)))" "$src/proj/result-fresh"
ln -s "$fixture/precious" "$src/proj/result-local"
for project in envproj busyenv; do
	mkdir -p "$src/$project/.direnv"
	ln -s /nix/store/fake-shell "$src/$project/.direnv/flake-profile-x"
	file "$src/$project/.direnv/flake-profile-x.rc"
done
(cd "$src/busyenv" && exec sleep 300) &
busy_pids+=($!)

# rustup: what pins, defaults, channels, and recent use keep.
toolchains="$HOME/.rustup/toolchains"
for name in stable nightly 1.70.0 1.71.0 1.72.0 1.80.0 1.81.0 nightly-2026-01-01; do
	file "$toolchains/$name-test-host/bin/rustc"
done
file "$toolchains/1.75.0-other-host/bin/rustc"
touch_recent "$toolchains/1.81.0-test-host/bin/rustc"
mkdir -p "$src/pinned" "$src/legacy" "$src/old/target/copy"
printf '[toolchain]\nchannel = "1.80.0"\n' >"$src/pinned/rust-toolchain.toml"
printf '1.72.0\n' >"$src/legacy/rust-toolchain"
# Inside a target dir this run deletes, so it pins nothing.
printf '[toolchain]\nchannel = "1.71.0"\n' >"$src/old/target/copy/rust-toolchain.toml"
uninstalled=(1.70.0-test-host 1.71.0-test-host nightly-2026-01-01-test-host)
installed=(stable-test-host nightly-test-host 1.72.0-test-host 1.80.0-test-host 1.81.0-test-host 1.75.0-other-host)

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
	"$src/proj/result"
	"$src/envproj/.direnv"
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
	"$src/proj/result-fresh"
	"$src/proj/result-local"
	"$profiles/profile-4-link"
	"$profiles/channels-1-link"
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
	expected_kept+=("$tmp/busy/data" "$src/busyenv/.direnv")
fi

for bad_age in 0 5x 1w 1234567h; do
	set +e
	run --age "$bad_age" --dry-run >/dev/null 2>&1
	status=$?
	set -e
	[ "$status" -eq 2 ] || fail "--age $bad_age: expected status 2, got $status"
done

# Paths the plan lists for deletion, without their sizes.
planned() {
	printf '%s\n' "$output" | awk '/^  / { sub(/^ +[^ ]+  /, ""); sub(/ \((git worktree remove|nix out-link)\)$/, ""); print }'
}

# Fails when the plan deletes paths rather than only running collectors.
expect_no_deletions() {
	if planned | grep -q '^/'; then
		fail "$1 planned deletions:$nl$output"
	fi
}

# Nothing in the fixture is 200 hours old yet.
output="$(run --age 200h --dry-run)"
expect_no_deletions "200h threshold"

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
case "$output" in *"$profiles/profile: delete generations 1 2 3$nl"*) ;; *) fail "dry run does not delete old generations${nl}$output" ;; esac
case "$output" in *"$profiles/channels:"*) fail "dry run deletes recent generations" ;; esac
for name in "${uninstalled[@]}"; do
	case "$output" in *"rustup toolchain uninstall $name$nl"*) ;; *) fail "dry run does not uninstall $name${nl}$output" ;; esac
done
for name in "${installed[@]}"; do
	case "$output" in *"rustup toolchain uninstall $name$nl"*) fail "dry run uninstalls $name" ;; esac
done
[ ! -s "$calls" ] || fail "dry run ran collectors:$nl$(cat "$calls")"
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
for name in "${uninstalled[@]}"; do
	assert_gone "$toolchains/$name"
done
for name in "${installed[@]}"; do
	assert_kept "$toolchains/$name"
done

# Deletions run first and nix-store --gc runs last, once roots are gone.
expected_calls="rustup toolchain uninstall 1.70.0-test-host
rustup toolchain uninstall 1.71.0-test-host
rustup toolchain uninstall nightly-2026-01-01-test-host
nix-env --profile $profiles/profile --delete-generations 1 2 3
docker system prune --all --force --filter until=2160m
nix-store --gc"
[ "$(cat "$calls")" = "$expected_calls" ] || fail "collector calls:$nl$(cat "$calls")${nl}expected:$nl$expected_calls"

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

# A second run finds nothing new to delete.
output="$(run --dry-run)"
expect_no_deletions "second run"
