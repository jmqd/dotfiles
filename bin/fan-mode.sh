#!/bin/sh
# Show or set the BMC fan mode on a Supermicro board. With no argument it
# only prints the current mode. With a mode name it sets that mode, which
# persists in the BMC across reboots. Needs root for /dev/ipmi0.
#
# Usage: sudo fan-mode.sh [standard|full|optimal|heavyio]

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
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
}

mode_code() {
	case "$1" in
	standard) RETVAL=0x00 ;;
	full) RETVAL=0x01 ;;
	optimal) RETVAL=0x02 ;;
	heavyio) RETVAL=0x04 ;;
	*)
		usage
		err "unknown mode: $1"
		;;
	esac
}

show_mode() {
	_raw="$(ipmitool raw 0x30 0x45 0x00)" || err "could not read fan mode"
	case "$(echo "$_raw" | tr -d ' ')" in
	00) _name=standard ;;
	01) _name=full ;;
	02) _name=optimal ;;
	04) _name=heavyio ;;
	*) _name="unknown ($_raw)" ;;
	esac
	say "fan mode: $_name"
}

main() {
	if [ $# -gt 1 ]; then
		usage
		err "too many arguments"
	fi
	case "${1:-}" in
	-h | --help)
		usage
		return 0
		;;
	esac

	need_cmd ipmitool
	need_cmd tr
	[ "$(id -u)" -eq 0 ] || err "run as root (sudo)"

	if [ $# -eq 1 ]; then
		mode_code "$1"
		ensure ipmitool raw 0x30 0x45 0x01 "$RETVAL" >/dev/null
	fi
	show_mode
}

main "$@" || exit 1
