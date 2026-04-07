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
		while [ "${1:-}" = "--force" ]; do
			shift
		done
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
		while [ "${1:-}" = "--force" ]; do
			shift
		done
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

cat >"$fake_bin/tail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-f" ]; then
	shift
fi

cat "$1"
EOF
chmod +x "$fake_bin/tail"

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

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	case "$haystack" in
	*"$needle"*)
		echo "expected output to not contain: $needle" >&2
		echo "$haystack" >&2
		exit 1
		;;
	*) ;;
	esac
}

assert_exists() {
	local path="$1"
	[ -e "$path" ] || {
		echo "expected path to exist: $path" >&2
		exit 1
	}
}

assert_eventually_exists() {
	local path="$1"
	local attempts="${2:-40}"
	while [ "$attempts" -gt 0 ]; do
		if [ -e "$path" ]; then
			return 0
		fi
		sleep 0.05
		attempts=$((attempts - 1))
	done
	assert_exists "$path"
}

assert_missing() {
	local path="$1"
	[ ! -e "$path" ] || {
		echo "expected path to be missing: $path" >&2
		exit 1
	}
}

setup_case() {
	local case_name="$1"
	case_dir="$tmp_dir/$case_name"
	state_dir="$case_dir/state"
	repo_dir="$case_dir/repo"
	home_dir="$case_dir/home"
	mkdir -p "$state_dir" "$repo_dir/.git" "$home_dir"

	export HIVE_FAKE_STATE="$state_dir"
	export HOME="$home_dir"
	export HIVE_STATE="$case_dir/hive-state"
}

hive() {
	local backend="$1"
	shift
	HIVE_BACKEND="$backend" bash "$repo_root/bin/hive" "$@"
}

run_docker_backend_smoke() {
	setup_case docker

	hive docker up --repo "$repo_dir" --agents 2 --cmd "echo hi" --host-store-ro --hardened

	assert_exists "$HIVE_STATE/worktrees/repo/agent-01/.git"
	assert_exists "$HIVE_STATE/worktrees/repo/agent-02/.git"
	assert_eventually_exists "$HIVE_STATE/logs/repo-agent-01.log"
	assert_eventually_exists "$HIVE_STATE/logs/repo-agent-02.log"

	local run_log
	run_log="$(cat "$state_dir/docker.log")"
	assert_contains "$run_log" '--cap-drop=ALL'
	assert_contains "$run_log" '/nix/store:/nix/store:ro'
	assert_contains "$run_log" 'hive-repo-agent-01'
	assert_contains "$run_log" 'hive-repo-agent-02'
	assert_contains "$run_log" "$HIVE_STATE/worktrees/repo/agent-01:$HIVE_STATE/worktrees/repo/agent-01"
	assert_contains "$run_log" "$repo_dir/.git:$repo_dir/.git"
	assert_contains "$run_log" 'sh -lc while :; do sleep 3600; done'

	local ls_output
	ls_output="$(hive docker ls --repo "$repo_dir")"
	assert_contains "$ls_output" 'hive-repo-agent-01'
	assert_contains "$ls_output" 'hive-repo-agent-02'

	local exec_output
	exec_output="$(hive docker exec --repo "$repo_dir" 01 pwd)"
	assert_contains "$exec_output" 'executed:hive-repo-agent-01:bash -lc pwd'
	assert_contains "$(cat "$state_dir/exec.log")" 'flags= name=hive-repo-agent-01 cmd=bash -lc pwd'

	local logs_output
	logs_output="$(hive docker logs --repo "$repo_dir" 01)"
	assert_contains "$logs_output" 'logs:hive-repo-agent-01'

	local down_output
	down_output="$(hive docker down --repo "$repo_dir")"
	assert_contains "$down_output" 'containers stopped for repo repo'
	assert_contains "$down_output" 'worktrees cleaned for repo repo'
	assert_not_contains "$down_output" 'host agents stopped'

	assert_missing "$HIVE_STATE/worktrees/repo/agent-01"
	assert_missing "$HIVE_STATE/worktrees/repo/agent-02"
	assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-01"
	assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-02"
}

run_host_backend_smoke() {
	setup_case host

	hive host up --repo "$repo_dir" --agents 2 --cmd "echo hi" --host-store-ro --hardened

	assert_exists "$HIVE_STATE/worktrees/repo/agent-01/.git"
	assert_exists "$HIVE_STATE/worktrees/repo/agent-02/.git"
	assert_eventually_exists "$HIVE_STATE/logs/repo-agent-01.log"
	assert_eventually_exists "$HIVE_STATE/logs/repo-agent-02.log"
	assert_exists "$HIVE_STATE/host/repo/agent-01.worktree"
	assert_exists "$HIVE_STATE/host/repo/agent-02.worktree"
	assert_contains "$(cat "$HIVE_STATE/host/repo/agent-01.worktree")" "$HIVE_STATE/worktrees/repo/agent-01"
	assert_contains "$(cat "$HIVE_STATE/host/repo/agent-02.worktree")" "$HIVE_STATE/worktrees/repo/agent-02"

	local ls_output
	ls_output="$(hive host ls --repo "$repo_dir")"
	assert_contains "$ls_output" 'hive-repo-agent-01'
	assert_contains "$ls_output" 'hive-repo-agent-02'
	assert_contains "$ls_output" 'repo'

	local exec_output
	exec_output="$(hive host exec --repo "$repo_dir" 01 pwd)"
	assert_contains "$exec_output" "$HIVE_STATE/worktrees/repo/agent-01"

	local logs_output
	logs_output="$(hive host logs --repo "$repo_dir" 01)"
	assert_contains "$logs_output" 'hi'

	local down_output
	down_output="$(hive host down --repo "$repo_dir")"
	assert_contains "$down_output" 'host agents stopped for repo repo'
	assert_contains "$down_output" 'worktrees cleaned for repo repo'
	assert_not_contains "$down_output" 'containers stopped'

	assert_missing "$HIVE_STATE/worktrees/repo/agent-01"
	assert_missing "$HIVE_STATE/worktrees/repo/agent-02"
	assert_missing "$HIVE_STATE/host/repo/agent-01.worktree"
	assert_missing "$HIVE_STATE/host/repo/agent-02.worktree"
	assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-01"
	assert_contains "$(cat "$state_dir/git.log")" "remove|$HIVE_STATE/worktrees/repo/agent-02"
}

run_docker_backend_smoke
run_host_backend_smoke
