#!/bin/sh
# Show BMC temperature sensors, fan mode, and recent VRM/throttle events
# on a Supermicro board, and archive the full BMC event log (SEL) to a
# timestamped file. Read-only unless --clear-log is given, which clears
# the SEL only after the archive is written. Needs root for /dev/ipmi0.
#
# Usage: sudo vrm-check.sh [--clear-log] [LOG_DIR]
#   LOG_DIR defaults to /var/log/vrm-check.

set -u

say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() { say "error: $1"; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

archive_sel() {
    _dir="$1"
    ensure mkdir -p "$_dir"
    _file="$_dir/sel-$(date +%Y%m%dT%H%M%S).txt"
    ensure ipmitool sel elist >"$_file"
    [ -s "$_file" ] || err "SEL archive is empty: $_file"
    say "saved SEL to $_file"
    RETVAL="$_file"
}

main() {
    _clear=no
    _dir=/var/log/vrm-check
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help) usage; return 0 ;;
            --clear-log) _clear=yes ;;
            -*) usage; err "unknown option: $_arg" ;;
            *) _dir="$_arg" ;;
        esac
    done

    need_cmd ipmitool
    need_cmd date
    need_cmd grep
    [ "$(id -u)" -eq 0 ] || err "run as root (sudo)"

    say "temperature sensors"
    ensure ipmitool sdr type Temperature

    say "fan mode (00 standard, 01 full, 02 optimal, 04 heavy IO)"
    ensure ipmitool raw 0x30 0x45 0x00

    archive_sel "$_dir"
    _file="$RETVAL"

    say "VRM and throttle events"
    grep -E 'VRM|Throttled' "$_file" || say "none"

    if [ "$_clear" = yes ]; then
        ensure ipmitool sel clear
        say "cleared SEL (archive kept at $_file)"
    fi
}

main "$@" || exit 1
