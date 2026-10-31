#!/bin/sh
# Temporarily cut CPU power to cool the VRMs: disable boost and cap the
# max frequency of the given CPUs (acpi-cpufreq). With "off", re-enable
# boost and restore every CPU's max to its hardware max. Changes last
# until reboot or "off". Needs root.
#
# Usage: sudo cpu-throttle.sh on [--mhz MHZ] [CPU_LIST]
#        sudo cpu-throttle.sh off
#   MHZ must be one of the CPU's P-states (scaling_available_frequencies,
#   e.g. 1500 2000 2450 on jmws); default is the minimum.
#   CPU_LIST is a cpuset list such as 0-63,128-191 (socket 1 on jmws);
#   default is all CPUs.

set -u

say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() { say "error: $1"; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

SYS=/sys/devices/system/cpu

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

# Args: KHZ (empty for each CPU's minimum), CPU_LIST (empty for all).
throttle_on() {
    if [ -n "$2" ]; then
        expand_list "$2"
        _cpus="$RETVAL"
    else
        _cpus="$(seq 0 $(($(getconf _NPROCESSORS_CONF) - 1)) | tr '\n' ' ')"
    fi
    for _c in $_cpus; do
        _f="$SYS/cpu$_c/cpufreq"
        [ -d "$_f" ] || err "no cpufreq for cpu$_c"
        if [ -n "$1" ]; then
            case " $(cat "$_f/scaling_available_frequencies") " in
                *" $1 "*) ;;
                *) err "$(($1 / 1000)) MHz is not a P-state of cpu$_c" ;;
            esac
        fi
    done
    write_file "$SYS/cpufreq/boost" 0
    _n=0
    for _c in $_cpus; do
        _f="$SYS/cpu$_c/cpufreq"
        if [ -n "$1" ]; then _khz="$1"; else _khz="$(cat "$_f/cpuinfo_min_freq")"; fi
        write_file "$_f/scaling_max_freq" "$_khz"
        _n=$((_n + 1))
    done
    if [ -n "$1" ]; then _to="$(($1 / 1000)) MHz"; else _to="minimum frequency"; fi
    say "boost off; capped $_n CPUs to $_to"
}

throttle_off() {
    for _f in "$SYS"/cpu[0-9]*/cpufreq; do
        write_file "$_f/scaling_max_freq" "$(cat "$_f/cpuinfo_max_freq")"
    done
    write_file "$SYS/cpufreq/boost" 1
    say "boost on; all CPUs restored to hardware max frequency"
}

main() {
    _cmd="${1:-}"
    case "$_cmd" in
        -h|--help) usage; return 0 ;;
        on|off) shift ;;
        *) usage; err "need 'on' or 'off'" ;;
    esac
    _khz=""
    _list=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --mhz)
                [ $# -ge 2 ] || err "--mhz needs a value"
                case "$2" in *[!0-9]*|'') err "bad MHz: $2" ;; esac
                _khz=$(($2 * 1000)); shift 2 ;;
            -*) usage; err "unknown option: $1" ;;
            *) [ -z "$_list" ] || err "too many arguments"; _list="$1"; shift ;;
        esac
    done
    [ "$_cmd" = on ] || [ -z "$_khz$_list" ] || err "'off' takes no arguments"
    need_cmd seq
    need_cmd tr
    need_cmd getconf
    [ "$(id -u)" -eq 0 ] || err "run as root (sudo)"
    [ -w "$SYS/cpufreq/boost" ] || err "no writable $SYS/cpufreq/boost"

    case "$_cmd" in
        on) throttle_on "$_khz" "$_list" ;;
        off) throttle_off ;;
    esac
}

main "$@" || exit 1
