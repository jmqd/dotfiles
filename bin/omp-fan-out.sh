#!/bin/sh
# Fans one omp session out into parallel forks: one `omp --fork SESSION [PROMPT]`
# per follow-up, each in its own git worktree (made with `omp wt add` next to the
# current repository) and its own WezTerm tab or tmux window. Reads the git
# repository of the current directory, $TMUX and $WEZTERM_PANE. By default it only
# prints the plan; --run creates the worktrees and branches and opens the tabs.
set -u

usage() {
	cat <<EOF
usage: ${0##*/} [--run] [--terminal wezterm|tmux] [--in-place] SESSION PROMPT...
       ${0##*/} [--run] [--terminal wezterm|tmux] [--in-place] -n COUNT SESSION

Open one forked omp session per PROMPT, each starting with that prompt as its
first message, or COUNT forks with no prompt. SESSION is an omp session id
(prefix) or .jsonl path. Options go before SESSION.

Fork i gets a new worktree ../<repo>-fan-<tag>-<i> on a new branch
fan/<tag>-<i>, where <tag> is the last 8 letters and digits of the session id.
Worktrees start at the current HEAD; uncommitted changes stay behind. Any
existing path, branch or worktree entry is an error, checked for every fork
before anything is created.

Options:
  --run              create the worktrees and open the forks (default: print
                     the plan and change nothing)
  --terminal NAME    wezterm or tmux (default: tmux when \$TMUX is set, else
                     wezterm when \$WEZTERM_PANE is set)
  --in-place         open every fork in the current directory, no worktrees
                     (for read-only follow-ups)
  -n COUNT           open COUNT forks without an initial prompt
  -h, --help         show this help

A prompt must not start with '-': omp would read it as a flag.
EOF
}

say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() {
	say "error: $1"
	exit 1
}
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

# Prints one argument quoted for a POSIX shell, bare when that is unambiguous.
quote() {
	case $1 in
	'' | *[!A-Za-z0-9_./=:@%+,-]*)
		printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
		;;
	*) printf '%s' "$1" ;;
	esac
}

# Prints a command line that a shell would run as exactly this argv.
show() {
	_line=
	for _arg in "$@"; do
		_line="$_line${_line:+ }$(quote "$_arg")"
	done
	printf '  %s\n' "$_line"
}

# Runs the command under --run; otherwise prints it.
step() {
	if [ "$run" -eq 1 ]; then
		ensure "$@"
	else
		show "$@"
	fi
}

# omp matches the id inside a session path or id prefix; the tag is its last 8
# letters and digits, the random end of a UUIDv7 session id.
session_tag() {
	_id=${1##*/}
	_id=${_id%.jsonl}
	_id=${_id##*_}
	_id=$(printf '%s' "$_id" | tr -cd 'A-Za-z0-9')
	while [ "${#_id}" -gt 8 ]; do
		_id=${_id#?}
	done
	printf '%s\n' "$_id"
}

# omp treats a SESSION with a slash, a backslash or .jsonl as a file path.
is_session_path() {
	case $1 in
	*/* | *\\* | *.jsonl) return 0 ;;
	esac
	return 1
}

fork_dir() {
	if [ "$in_place" -eq 1 ]; then
		printf '%s\n' "$here"
	else
		printf '%s\n' "$parent/$repo-fan-$tag-$1"
	fi
}

fork_branch() { printf '%s\n' "fan/$tag-$1"; }

# Fails when fork $1's worktree path, branch or worktree entry already exists.
check_fork() {
	_dir=$(fork_dir "$1")
	_branch=$(fork_branch "$1")
	if [ -e "$_dir" ] || [ -L "$_dir" ]; then
		err "$_dir already exists"
	fi
	if git -C "$top" show-ref --verify --quiet "refs/heads/$_branch"; then
		err "branch $_branch already exists"
	fi
	if printf '%s\n' "$worktrees" | grep -Fqx "worktree $_dir"; then
		err "$_dir is still registered as a worktree; see 'git worktree prune'"
	fi
}

# Opens a tab or window titled $2 in directory $1 running the argv after them.
# The terminal server, not this shell, starts the program, so the argv carries
# an absolute omp path and the omp profile variables of this shell.
launch() {
	_dir=$1
	_title=$2
	shift 2
	case $terminal in
	wezterm)
		if [ "$run" -eq 1 ]; then
			_pane=$(wezterm cli spawn --cwd "$_dir" -- "$@") ||
				err "command failed: wezterm cli spawn --cwd $_dir -- $*"
			ensure wezterm cli set-tab-title --pane-id "$_pane" "$_title"
			say "opened WezTerm pane $_pane in $_dir"
		else
			show wezterm cli spawn --cwd "$_dir" -- "$@"
			show wezterm cli set-tab-title --pane-id '<new pane id>' "$_title"
		fi
		;;
	tmux)
		step tmux new-window -c "$_dir" -n "$_title" -- "$@"
		;;
	esac
}

# Opens fork $1, with the prompt in $2 when given.
open_fork() {
	_i=$1
	shift
	launch "$(fork_dir "$_i")" "fan $_i" env \
		${OMP_PROFILE+"OMP_PROFILE=$OMP_PROFILE"} \
		${PI_CODING_AGENT_DIR+"PI_CODING_AGENT_DIR=$PI_CODING_AGENT_DIR"} \
		"$omp_bin" --fork "$session" "$@"
}

main() {
	run=0
	terminal=
	in_place=0
	count=
	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		--run) run=1 ;;
		--in-place) in_place=1 ;;
		--terminal)
			[ $# -ge 2 ] || err "--terminal needs a value"
			terminal=$2
			shift
			;;
		--terminal=*) terminal=${1#*=} ;;
		-n)
			[ $# -ge 2 ] || err "-n needs a value"
			count=$2
			shift
			;;
		--)
			shift
			break
			;;
		-*) err "unknown option: $1 (see --help)" ;;
		*) break ;;
		esac
		shift
	done
	if [ $# -eq 0 ]; then
		usage >&2
		return 1
	fi
	session=$1
	shift

	need_cmd omp
	need_cmd sed
	need_cmd tr
	omp_bin=$(command -v omp)
	case $omp_bin in
	/*) ;;
	*) err "omp resolves to '$omp_bin', not an executable path" ;;
	esac

	if [ -n "$count" ]; then
		[ $# -eq 0 ] || err "give prompts or -n COUNT, not both"
		case $count in
		'' | *[!0-9]*) err "-n needs a positive integer, got '$count'" ;;
		esac
		[ "$count" -ge 1 ] || err "-n needs a positive integer, got '$count'"
		total=$count
	else
		[ $# -ge 1 ] || err "give at least one PROMPT, or -n COUNT for forks without one"
		for _prompt in "$@"; do
			case $_prompt in
			'') err "empty prompt" ;;
			-*) err "prompt starts with '-', which omp reads as a flag: $_prompt" ;;
			esac
		done
		total=$#
	fi

	# The forks start elsewhere, so a relative session path must become absolute.
	if is_session_path "$session"; then
		[ -f "$session" ] || err "session file not found: $session"
		case $session in
		*/*) _sdir=$(cd -- "${session%/*}/" && pwd -P) || err "cannot resolve $session" ;;
		*) _sdir=$(pwd -P) || err "cannot resolve the current directory" ;;
		esac
		session="$_sdir/${session##*/}"
	fi
	tag=$(session_tag "$session")
	[ -n "$tag" ] || err "no letters or digits in the session id: $session"

	if [ -z "$terminal" ]; then
		if [ -n "${TMUX:-}" ]; then
			terminal=tmux
		elif [ -n "${WEZTERM_PANE:-}" ]; then
			terminal=wezterm
		else
			err "not inside tmux or WezTerm; pass --terminal wezterm|tmux"
		fi
	fi
	case $terminal in
	wezterm | tmux) ;;
	*) err "unknown terminal '$terminal' (want wezterm or tmux)" ;;
	esac
	need_cmd "$terminal"

	here=$(pwd -P) || err "cannot resolve the current directory"
	if [ "$in_place" -eq 0 ]; then
		need_cmd git
		need_cmd grep
		top=$(git rev-parse --show-toplevel 2>/dev/null) ||
			err "$here is not in a git repository (use --in-place to fork without worktrees)"
		repo=${top##*/}
		parent=${top%/*}
		worktrees=$(git -C "$top" worktree list --porcelain) ||
			err "cannot list the worktrees of $top"
		if git -C "$top" show-ref --verify --quiet refs/heads/fan; then
			err "branch 'fan' exists, so branches under fan/ cannot be created"
		fi
		_i=1
		while [ "$_i" -le "$total" ]; do
			check_fork "$_i"
			_i=$((_i + 1))
		done
	fi

	if [ "$run" -eq 1 ]; then
		say "opening $total fork(s) of $session in $terminal"
	else
		printf 'Plan: %s fork(s) of %s in %s\n' "$total" "$session" "$terminal"
	fi
	_i=1
	while [ "$_i" -le "$total" ]; do
		if [ "$in_place" -eq 1 ]; then
			printf 'fork %s: %s (in place)\n' "$_i" "$here"
		else
			printf 'fork %s: %s on new branch %s\n' "$_i" "$(fork_dir "$_i")" "$(fork_branch "$_i")"
		fi
		_i=$((_i + 1))
	done
	if [ "$in_place" -eq 0 ] && [ -n "$(git -C "$top" status --porcelain)" ]; then
		say "warning: $top has uncommitted changes; the worktrees start at HEAD without them"
	fi

	[ "$run" -eq 1 ] || printf 'Commands:\n'
	if [ "$in_place" -eq 0 ]; then
		_i=1
		while [ "$_i" -le "$total" ]; do
			step "$omp_bin" wt add -C "$top" -b "$(fork_branch "$_i")" "$(fork_dir "$_i")"
			_i=$((_i + 1))
		done
	fi
	_i=1
	if [ -n "$count" ]; then
		while [ "$_i" -le "$total" ]; do
			open_fork "$_i"
			_i=$((_i + 1))
		done
	else
		for _prompt in "$@"; do
			open_fork "$_i" "$_prompt"
			_i=$((_i + 1))
		done
	fi
	[ "$run" -eq 1 ] || say "dry run: nothing changed; pass --run to do this"
}

main "$@" || exit 1
