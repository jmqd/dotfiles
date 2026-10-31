#!/bin/sh
# Temporarily cut CPU power to cool the VRMs: disable boost and cap the
# max frequency of the given CPUs to their minimum (acpi-cpufreq). With
# "off", re-enable boost and restore every CPU's max to its hardware max.
# Changes last until reboot or "off". Needs root.
#
# Usage: sudo cpu-throttle.sh on [CPU_LIST]   (default: all CPUs)
#        sudo cpu-throttle.sh off
#   CPU_LIST is a cpuset list such as 0-63,128-191 (socket 1 on jmws).

set -u

say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() { say "error: $1"; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

SYS=/sys/devices/system/cpu

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

write_file() {
    printf '%s\n' "$2" >"$1" || err "could not write $2 to $1"
}

# Expand a cpuset list like 0-3,8 into space-separated CPU numbers.
expand_list() {
    RETVAL=""
    _old_ifs="$IFS"; IFS=,
    for _part in $1; do
        case "$_part" in
            *-*) _lo="${_part%-*}"; _hi="${_part#*-}" ;;
            *) _lo="$_part"; _hi="$_part" ;;
        esac
        case "$_lo$_hi" in *[!0-9]*|'') IFS="$_old_ifs"; err "bad CPU list: $1" ;; esac
        RETVAL="$RETVAL $(seq "$_lo" "$_hi" | tr '\n' ' ')"
    done
    IFS="$_old_ifs"
}

throttle_on() {
    if [ -n "${1:-}" ]; then
        expand_list "$1"
        _cpus="$RETVAL"
    else
        _cpus="$(seq 0 $(($(getconf _NPROCESSORS_CONF) - 1)) | tr '\n' ' ')"
    fi
    for _c in $_cpus; do
        _f="$SYS/cpu$_c/cpufreq"
        [ -d "$_f" ] || err "no cpufreq for cpu$_c"
    done
    write_file "$SYS/cpufreq/boost" 0
    _n=0
    for _c in $_cpus; do
        _f="$SYS/cpu$_c/cpufreq"
        write_file "$_f/scaling_max_freq" "$(cat "$_f/cpuinfo_min_freq")"
        _n=$((_n + 1))
    done
    say "boost off; capped $_n CPUs to minimum frequency"
}

throttle_off() {
    for _f in "$SYS"/cpu[0-9]*/cpufreq; do
        write_file "$_f/scaling_max_freq" "$(cat "$_f/cpuinfo_max_freq")"
    done
    write_file "$SYS/cpufreq/boost" 1
    say "boost on; all CPUs restored to hardware max frequency"
}

main() {
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        on|off) ;;
        *) usage; err "need 'on' or 'off'" ;;
    esac
    need_cmd seq
    need_cmd tr
    need_cmd getconf
    [ "$(id -u)" -eq 0 ] || err "run as root (sudo)"
    [ -w "$SYS/cpufreq/boost" ] || err "no writable $SYS/cpufreq/boost"

    case "$1" in
        on) throttle_on "${2:-}" ;;
        off) throttle_off ;;
    esac
}

main "$@" || exit 1
