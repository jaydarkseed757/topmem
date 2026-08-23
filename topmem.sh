#!/usr/bin/env bash
#
# topmem.sh — report the processes consuming the most memory
#
# Scans /proc for every running process, aggregates resident memory, swap, and
# KSM profit by command name, and prints the top N. Read-only: it reads /proc
# and writes a table to stdout, and changes nothing on disk.
#
# Author:       jc
# Created:      <2026-08-23>
# Usage:        topmem.sh [-s rss|swap|ksm] [N]
#
set -euo pipefail

# --- constants -------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_SIZE=10

SORT_BY='rss'
SIZE="$DEFAULT_SIZE"

# Per-process results come back in globals. A command substitution would fork a
# subshell for every PID on the host, which is the dominant cost in this script.
_name=''
_rss=0
_swap=0
_ksm=0

RECORDS=()

# --- logging (must precede everything that can fail) -----------------------
_log() {
    local level="$1"; shift
    printf '%s %s[%d]: %s: %s\n' \
        "$(date --iso-8601=seconds)" "$SCRIPT_NAME" "$$" "$level" "$*" >&2
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { if [[ "${DEBUG:-0}" == "1" ]]; then _log DEBUG "$@"; fi; }
die()       { log_error "$@"; exit 1; }

# --- usage -----------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [-s rss|swap|ksm] [N]
Try '$SCRIPT_NAME --help' for more information.
EOF
    exit 2
}

arg_error() {
    log_error "$@"
    usage
}

print_help() {
    cat <<EOF
Show the top N processes by memory consumption.

Usage: $SCRIPT_NAME [OPTIONS] [N]

Arguments:
  N                  Number of entries to show [default: $DEFAULT_SIZE]

Options:
  -s, --sort <TYPE>  Column to sort by: rss, swap, ksm [default: rss]
  -h, --help         Show this message

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME 20
  $SCRIPT_NAME --sort swap
  $SCRIPT_NAME -s ksm 25
EOF
    exit 0
}

# --- argument parsing ------------------------------------------------------
parse_arguments() {
    local size_raw=''
    local end_of_options=0

    while (( $# > 0 )); do

        if (( end_of_options )); then
            if [[ -n "$size_raw" ]]; then arg_error "unexpected argument: $1"; fi
            size_raw="$1"
            shift
            continue
        fi

        case "$1" in
            -s|--sort)
                if (( $# < 2 )); then arg_error "missing value for $1"; fi
                # An option-shaped value means the operand was forgotten, not
                # that the user wants a column named '--help'.
                case "$2" in -*) arg_error "missing value for $1" ;; esac
                SORT_BY="$2"
                shift 2
                ;;

            --sort=*)
                SORT_BY="${1#*=}"
                if [[ -z "$SORT_BY" ]]; then arg_error 'missing value for --sort'; fi
                shift
                ;;

            -h|--help)
                print_help
                ;;

            --)
                end_of_options=1
                shift
                ;;

            -*)
                arg_error "unknown option: $1"
                ;;

            *)
                if [[ -n "$size_raw" ]]; then arg_error "unexpected argument: $1"; fi
                size_raw="$1"
                shift
                ;;
        esac

    done

    if [[ -n "$size_raw" ]]; then
        if [[ ! "$size_raw" =~ ^[0-9]+$ ]]; then
            arg_error "N must be a positive integer: $size_raw"
        fi
        # 10# forces base 10; bash reads a zero-padded value such as 08 as octal.
        SIZE=$(( 10#$size_raw ))
        if (( SIZE < 1 )); then arg_error 'N must be greater than zero'; fi
    fi

    case "$SORT_BY" in
        rss|swap|ksm) ;;
        *) arg_error "unknown sort column: $SORT_BY (expected rss, swap, or ksm)" ;;
    esac

    # ksm_stat arrived in Linux 6.1. Without it every KSM figure is zero and
    # sorting on the column returns an arbitrary set of processes.
    if [[ "$SORT_BY" == 'ksm' && ! -r /proc/self/ksm_stat ]]; then
        die 'kernel does not expose /proc/<pid>/ksm_stat; --sort ksm is unavailable'
    fi
}

# --- per-process readers ---------------------------------------------------
read_cmdline() {
    _name=''
    # cmdline is NUL-separated; read -d '' takes the first field and stops.
    IFS= read -r -d '' _name 2>/dev/null < "/proc/$1/cmdline" || return 1
    if [[ -z "$_name" ]]; then return 1; fi
    # Records are tab-delimited and newline-terminated; a command line
    # containing either would shift every field downstream.
    _name="${_name//[$'\t\n']/ }"
    return 0
}

read_status() {
    local key value
    _rss=''
    _swap=0
    while read -r key value _; do
        case "$key" in
            VmRSS:)  _rss="$value"  ;;
            VmSwap:) _swap="$value" ;;
        esac
    done 2>/dev/null < "/proc/$1/status" || return 1
    if [[ -z "$_rss" ]]; then return 1; fi
    return 0
}

read_ksm() {
    local key value
    _ksm=0
    if [[ ! -r "/proc/$1/ksm_stat" ]]; then return 0; fi
    while read -r key value _; do
        if [[ "$key" == 'ksm_process_profit' ]]; then
            _ksm="$value"
            break
        fi
    done 2>/dev/null < "/proc/$1/ksm_stat" || return 0
    # Profit is signed: a process can be a net loss for KSM.
    if [[ ! "$_ksm" =~ ^-?[0-9]+$ ]]; then _ksm=0; fi
    return 0
}

# --- collection ------------------------------------------------------------
collect_processes() {
    local path pid

    for path in /proc/[0-9]*; do
        pid="${path#/proc/}"
        if [[ ! -d "$path" ]]; then continue; fi

        # A process may exit at any point during the scan.
        read_cmdline "$pid" || continue
        read_status "$pid" || continue
        read_ksm "$pid"

        RECORDS+=( "${_rss}"$'\t'"${_swap}"$'\t'"${_ksm}"$'\t'"${_name}" )
    done
}

# --- reporting -------------------------------------------------------------
print_top() {
    local sort_column

    case "$SORT_BY" in
        rss)  sort_column=1 ;;
        swap) sort_column=2 ;;
        ksm)  sort_column=3 ;;
    esac

    printf '%-9s %-35s %-9s %-s\n' \
        'MEMORY' "Top $SIZE processes" 'SWAP' 'KSM'

    # %d, not %s: awk's CONVFMT would render large sums as 8.38861e+06, which
    # sort -n cannot compare.
    printf '%s\n' "${RECORDS[@]}" \
        | awk -F '\t' '
            {
                rss[$4]  += $1
                swap[$4] += $2
                ksm[$4]  += $3
            }
            END {
                for (name in rss)
                    printf "%d\t%d\t%d\t%s\n", rss[name], swap[name], ksm[name], name
            }
          ' \
        | sort -t $'\t' -k"${sort_column},${sort_column}"nr \
        | awk -F '\t' -v limit="$SIZE" '
            function basename(path,   n, parts) {
                n = split(path, parts, "/")
                return parts[n]
            }
            # status reports VmRSS and VmSwap in kB; ksm_stat reports profit in bytes.
            function kib_mib(k)  { return sprintf("%.0fM", k / 1024) }
            function byte_mib(b) { return sprintf("%.0fM", b / 1048576) }

            # Truncate by skipping, not by exiting: an early exit would SIGPIPE
            # sort, and pipefail would turn that into a script failure.
            NR > limit { next }
            {
                name = basename($4)
                if (length(name) > 25)
                    name = substr(name, 1, 25) "..."

                printf "%-9s %-35s %-9s %-s\n",
                       kib_mib($1), name, kib_mib($2), byte_mib($3)
            }
          '
}

# --- main ------------------------------------------------------------------
main() {
    parse_arguments "$@"
    collect_processes

    if (( ${#RECORDS[@]} == 0 )); then die 'no readable processes found in /proc'; fi

    print_top
}

main "$@"
