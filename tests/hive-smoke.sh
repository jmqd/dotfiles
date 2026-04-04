#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/fake-bin"
state_dir="$tmp_dir/state"
repo_dir="$tmp_dir/repo"
home_dir="$tmp_dir/home"
mkdir -p "$fake_bin" "$state_dir" "$repo_dir/.git" "$home_dir"

export PATH="$fake_bin:$PATH"
export HIVE_FAKE_STATE="$state_dir"
export HOME="$home_dir"
export HIVE_STATE="$tmp_dir/hive-state"

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${HIVE_FAKE_STATE:?}"
mkdir -p "$state_dir"

git_cwd="$(pwd)"
if [ "${1:-}" = "-C" ]; then
	git_cwd="$2"
	shift 2
fi

case "${1:-}" in
worktree)
	shift
	case "${1:-}" in
	add)
		shift
		if [ "${1:-}" = "--detach" ]; then
			shift
		fi
		worktree="$1"
		ref="$2"
		mkdir -p "$worktree/.git"
		printf 'add|%s|%s\n' "$worktree" "$ref" >>"$state_dir/git.log"
		;;
	remove)
		shift
		if [ "${1:-}" = "--force" ]; then
			shift
		fi
		worktree="$1"
		rm -rf "$worktree"
		printf 'remove|%s\n' "$worktree" >>"$state_dir/git.log"
		;;
	esac
	;;
rev-parse)
	shift
	if [ "${1:-}" = "--show-toplevel" ]; then
		printf '%s\n' "$git_cwd"
	else
		echo "unsupported fake git rev-parse invocation" >&2
		exit 1
	fi
	;;
*)
	echo "unsupported fake git invocation: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$fake_bin/git"

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${HIVE_FAKE_STATE:?}"
containers_file="$state_dir/containers"
volumes_file="$state_dir/volumes"
log_file="$state_dir/docker.log"
mkdir -p "$state_dir"
touch "$containers_file" "$volumes_file" "$log_file"

match_container() {
	local name="$1" repo="$2" agent="$3"
	shift 3
	local filter
	for filter in "$@"; do
		case "$filter" in
		label=agent-hive)
			;;
		label=hive.repo=*)
			[ "$repo" = "${filter#label=hive.repo=}" ] || return 1
			;;
		label=hive.agent=*)
			[ "$agent" = "${filter#label=hive.agent=}" ] || return 1
			;;
		name=^*)
			expected="${filter#name=^}"
			expected="${expected%\$}"
			[ "$name" = "$expected" ] || return 1
			;;
		*)
			echo "unsupported fake docker filter: $filter" >&2
			exit 1
			;;
		esac
	done
	return 0
}

case "${1:-}" in
info)
	exit 0
	;;
volume)
	shift
	case "${1:-}" in
	inspect)
		shift
		grep -Fxq "$1" "$volumes_file"
		;;
	create)
		shift
		if ! grep -Fxq "$1" "$volumes_file"; then
			echo "$1" >>"$volumes_file"
		fi
		printf '%s\n' "$1"
		;;
	*)
		echo "unsupported fake docker volume invocation: $*" >&2
		exit 1
		;;
	esac
	;;
ps)
	shift
	quiet=0
	format=""
	filters=()
	while [ $# -gt 0 ]; do
		case "$1" in
		-a)
			shift
			;;
		-q|-aq|-qa)
			quiet=1
			shift
			;;
		-f|--filter)
			filters+=("$2")
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$format" == table* ]]; then
		printf 'NAMES\tSTATUS\tREPO\tAGENT\n'
	fi

	while IFS='|' read -r name repo agent; do
		[ -n "$name" ] || continue
		if ! match_container "$name" "$repo" "$agent" "${filters[@]}"; then
			continue
		fi

		if [ "$quiet" -eq 1 ]; then
			printf '%s\n' "$name"
		elif [ "$format" = '{{.Names}}' ]; then
			printf '%s\n' "$name"
		elif [[ "$format" == table* ]]; then
			printf '%s\t%s\t%s\t%s\n' "$name" 'Up' "$repo" "$agent"
		else
			printf '%s\n' "$name"
		fi
	done <"$containers_file"
	;;
run)
	printf 'run|%s\n' "$*" >>"$log_file"
	shift
	name=""
	repo=""
	agent=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--name)
			name="$2"
			shift 2
			;;
		--label)
			case "$2" in
			hive.repo=*) repo="${2#hive.repo=}" ;;
			hive.agent=*) agent="${2#hive.agent=}" ;;
			esac
			shift 2
			;;
		-v|-w|-e|--security-opt|--tmpfs|--pids-limit|--cap-drop)
			shift 2
			;;
		-d|--cap-drop=ALL|--security-opt=no-new-privileges)
			shift
			;;
		*)
			break
			;;
		esac
	done
	printf '%s|%s|%s\n' "$name" "$repo" "$agent" >>"$containers_file"
	;;
rm)
	shift
	if [ "${1:-}" = "-f" ]; then
		shift
	fi
	printf 'rm|%s\n' "$*" >>"$log_file"
	tmp_file="$state_dir/containers.next"
	: >"$tmp_file"
	while IFS='|' read -r name repo agent; do
		[ -n "$name" ] || continue
		remove=0
		for target in "$@"; do
			if [ "$name" = "$target" ]; then
				remove=1
			fi
		done
		if [ "$remove" -eq 0 ]; then
			printf '%s|%s|%s\n' "$name" "$repo" "$agent" >>"$tmp_file"
		fi
	done <"$containers_file"
	mv "$tmp_file" "$containers_file"
	;;
exec)
	printf 'exec|%s\n' "$*" >>"$log_file"
	shift
	flags=()
	while [ $# -gt 0 ]; do
		case "$1" in
		-d|-i|-t)
			flags+=("$1")
			shift
			;;
		*)
			break
			;;
		esac
	done
	name="$1"
	shift
	printf 'flags=%s name=%s cmd=%s\n' "${flags[*]-}" "$name" "$*" >>"$state_dir/exec.log"
	if [[ " ${flags[*]-} " == *' -d '* ]]; then
		printf 'background:%s\n' "$name"
	else
		printf 'executed:%s:%s\n' "$name" "$*"
	fi
	;;
logs)
	shift
	if [ "${1:-}" = "-f" ]; then
		shift
	fi
	printf 'logs:%s\n' "$1"
	;;
inspect)
	shift
	name="$1"
	shift
	if [ "$1" != "--format" ]; then
		echo "unsupported fake docker inspect invocation: $*" >&2
		exit 1
	fi
	format="$2"
	while IFS='|' read -r current_name repo agent; do
		[ -n "$current_name" ] || continue
		if [ "$current_name" = "$name" ]; then
			case "$format" in
			*'hive.repo'*) printf '%s\n' "$repo" ;;
			*'hive.agent'*) printf '%s\n' "$agent" ;;
			*)
				echo "unsupported fake docker inspect format: $format" >&2
				exit 1
				;;
			esac
			exit 0
		fi
	done <"$containers_file"
	exit 1
	;;
*)
	echo "unsupported fake docker invocation: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$fake_bin/docker"

assert_contains() {
	local haystack="$1"
	local needle="$2"
	case "$haystack" in
	*"$needle"*) ;;
	*)
		echo "expected output to contain: $needle" >&2
		echo "$haystack" >&2
		exit 1
		;;
	esac
}

hive() {
	bash "$repo_root/bin/hive" "$@"
}

hive up --repo "$repo_dir" --agents 2 --cmd "echo hi" --host-store-ro --hardened

[ -d "$HIVE_STATE/worktrees/repo/agent-01/.git" ]
[ -d "$HIVE_STATE/worktrees/repo/agent-02/.git" ]
[ -f "$HIVE_STATE/logs/repo-agent-01.log" ]
[ -f "$HIVE_STATE/logs/repo-agent-02.log" ]

run_log="$(cat "$state_dir/docker.log")"
assert_contains "$run_log" '--cap-drop=ALL'
assert_contains "$run_log" '/nix/store:/nix/store:ro'
assert_contains "$run_log" 'hive-repo-agent-01'
assert_contains "$run_log" 'hive-repo-agent-02'

ls_output="$(hive ls --repo "$repo_dir")"
assert_contains "$ls_output" 'hive-repo-agent-01'
assert_contains "$ls_output" 'hive-repo-agent-02'

exec_output="$(hive exec --repo "$repo_dir" 01 pwd)"
assert_contains "$exec_output" 'executed:hive-repo-agent-01:sh -c pwd'
assert_contains "$(cat "$state_dir/exec.log")" 'flags= name=hive-repo-agent-01 cmd=sh -c pwd'

logs_output="$(hive logs --repo "$repo_dir" 01)"
assert_contains "$logs_output" 'logs:hive-repo-agent-01'

hive down --repo "$repo_dir"

[ ! -d "$HIVE_STATE/worktrees/repo/agent-01" ]
[ ! -d "$HIVE_STATE/worktrees/repo/agent-02" ]
assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-01"
assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-02"
