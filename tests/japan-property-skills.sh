#!/bin/sh
# Test the Japan property skills: japan-property-search and
# japan-property-brochure.
#
# Runs each skill's Python unit tests and checks that the files the two
# skills share are identical copies. Reads the skills under
# home/.pi/agent/skills of this repository, or of the directory given as the
# first argument. Changes nothing: the unit tests write only to temporary
# directories and read no network.

set -u

say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() {
	say "error: $1"
	exit 1
}
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

usage() {
	cat <<EOF
usage: ${0##*/} [SKILLS_DIR]

Run the unit tests of the Japan property skills and check their shared files.

SKILLS_DIR  directory holding japan-property-search and
            japan-property-brochure (default: home/.pi/agent/skills of the
            repository this script is in)
EOF
}

# Each skill is installed on its own, so each carries a copy of the files
# both need. The search skill's copy is the original.
same_file() {
	cmp -s "$1" "$2" || err "$2 differs from $1; copy the first over the second"
}

main() {
	case "${1:-}" in
	-h | --help)
		usage
		return 0
		;;
	esac
	need_cmd python3
	need_cmd cmp

	repo_root="$(cd "$(dirname "$0")/.." && pwd)" || err "cannot find the repository root"
	skills="${1:-$repo_root/home/.pi/agent/skills}"
	search="$skills/japan-property-search"
	brochure="$skills/japan-property-brochure"
	[ -d "$search" ] || err "no such directory: $search"
	[ -d "$brochure" ] || err "no such directory: $brochure"

	same_file "$search/scripts/jpx.js" "$brochure/scripts/jpx.js"
	same_file "$search/scripts/jpsearch/robots.py" "$brochure/scripts/brochure/robots.py"

	# -B: leave no __pycache__ in the repository.
	ensure python3 -B -m unittest discover -s "$search/tests"
	ensure python3 -B -m unittest discover -s "$brochure/tests"
	say "ok"
}

main "$@" || exit 1
