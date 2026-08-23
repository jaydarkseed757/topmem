#!/usr/bin/env bash
#
# topmem.sh — report the processes consuming the most memory
#
# Scans /proc for every running process, aggregates memory by command name, and
# prints the top N as a table or as tab-separated records. Can write a snapshot
# for later comparison and diff two snapshots to show growth over time.
# Read-only against the system; the only file it writes is a requested snapshot.
#
# Author:       <author>
# Created:      <YYYY-MM-DD>
# Modified:     2026-08-23, Claude Opus 5
# Version:      1.0
# Requires:     awk, sort, date, mktemp; journalctl only for --oom-log
# Usage:        topmem.sh [OPTIONS] [N] | topmem.sh --diff OLD NEW
#
set -euo pipefail

# Cron and systemd hand down whatever environment they were started with, and
# this script may write a snapshot file.
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'
umask 077

# --- constants -------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly VERSION='1.0'
readonly DEFAULT_SIZE=10

# Bumped only on an incompatible change to the snapshot layout. --diff refuses
# a file whose format it does not recognise rather than misreading the columns.
readonly SNAPSHOT_FORMAT=1
readonly TSV_HEADER=$'rss_kb\tswap_kb\tksm_bytes\tname\tpss_kb\toom_score'

SORT_BY='rss'
SIZE="$DEFAULT_SIZE"          # 0 means unlimited; mapfile -n 0 reads every row.
OUTPUT_FORMAT='table'
UNIT='auto'
SHOW_HEADER=1
WITH_PSS=0
WITH_OOM_LOG=0
SNAPSHOT_PATH=''
DIFF_OLD=''
DIFF_NEW=''
MODE='report'

MEM_TOTAL_KB=0
MEM_AVAILABLE_KB=0
HOST_NAME='unknown'

# Per-process results come back in globals. A command substitution would fork a
# subshell for every PID on the host, which is the dominant cost in this script.
_name=''
_rss=0
_swap=0
_ksm=0
_pss=-1
_oom=0

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
Usage: $SCRIPT_NAME [OPTIONS] [N]
       $SCRIPT_NAME --diff OLD_SNAPSHOT NEW_SNAPSHOT
Try '$SCRIPT_NAME --help' for more information.
EOF
    exit 2
}

arg_error() {
    log_error "$@"
    usage
}

print_version() {
    printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
    exit 0
}

print_help() {
    cat <<EOF
Show the processes consuming the most memory, grouped by command name.

Usage: $SCRIPT_NAME [OPTIONS] [N]
       $SCRIPT_NAME --diff OLD_SNAPSHOT NEW_SNAPSHOT

Arguments:
  N                    Number of entries to show [default: $DEFAULT_SIZE]

Options:
  -s, --sort <TYPE>    Sort column: rss, pss, swap, ksm [default: rss]
                       'pss' requires --pss
  -u, --unit <UNIT>    Size unit: auto, K, M, G [default: auto]
      --pss            Collect proportional set size from smaps_rollup.
                       More accurate than RSS for shared memory, but the
                       kernel walks page tables per process to produce it
      --tsv            Emit tab-separated records with raw units, for parsing
      --no-header      Suppress header lines in either format
      --oom-log        Append recent kernel OOM kills from the journal
  -a, --all            Show every command name; cannot be combined with N
      --snapshot FILE  Write results to FILE for later comparison.
                       Implies --all unless N or --all is given explicitly
      --diff OLD NEW   Compare two snapshots and report growth per command
  -V, --version        Print version and exit
  -h, --help           Show this message

TSV columns, in order:
  rss_kb  swap_kb  ksm_bytes  name  pss_kb  oom_score

New columns are only ever appended, so field positions are stable. pss_kb is
-1 when --pss was not given; oom_score is the highest score in the group.

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME 20
  $SCRIPT_NAME --pss --sort pss
  $SCRIPT_NAME --oom-log
  $SCRIPT_NAME --tsv --all --no-header > /var/tmp/topmem.tsv
  $SCRIPT_NAME --snapshot "/var/tmp/topmem.\$(date +%s).snap"
  $SCRIPT_NAME --diff /var/tmp/topmem.1.snap /var/tmp/topmem.2.snap
EOF
    exit 0
}

# --- argument parsing ------------------------------------------------------
parse_arguments() {
    local size_raw=''
    local all_requested=0
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

            -u|--unit)
                if (( $# < 2 )); then arg_error "missing value for $1"; fi
                case "$2" in -*) arg_error "missing value for $1" ;; esac
                UNIT="$2"
                shift 2
                ;;

            --unit=*)
                UNIT="${1#*=}"
                if [[ -z "$UNIT" ]]; then arg_error 'missing value for --unit'; fi
                shift
                ;;

            --pss)
                WITH_PSS=1
                shift
                ;;

            --tsv)
                OUTPUT_FORMAT='tsv'
                shift
                ;;

            --no-header)
                SHOW_HEADER=0
                shift
                ;;

            --oom-log)
                WITH_OOM_LOG=1
                shift
                ;;

            -a|--all)
                all_requested=1
                shift
                ;;

            --snapshot)
                if (( $# < 2 )); then arg_error "missing value for $1"; fi
                case "$2" in -*) arg_error "missing value for $1" ;; esac
                SNAPSHOT_PATH="$2"
                shift 2
                ;;

            --snapshot=*)
                SNAPSHOT_PATH="${1#*=}"
                if [[ -z "$SNAPSHOT_PATH" ]]; then
                    arg_error 'missing value for --snapshot'
                fi
                shift
                ;;

            --diff)
                if (( $# < 3 )); then
                    arg_error '--diff requires two snapshot files'
                fi
                DIFF_OLD="$2"
                DIFF_NEW="$3"
                MODE='diff'
                shift 3
                ;;

            -V|--version)
                print_version
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

    # Rejected rather than resolved by precedence: a caller who wrote both had
    # one of the two in mind, and guessing which silently truncates their data.
    if (( all_requested )) && [[ -n "$size_raw" ]]; then
        arg_error '--all and an explicit N are mutually exclusive'
    fi

    if (( all_requested )); then
        SIZE=0
    elif [[ -n "$size_raw" ]]; then
        if [[ ! "$size_raw" =~ ^[0-9]+$ ]]; then
            arg_error "N must be a positive integer: $size_raw"
        fi
        # 10# forces base 10; bash reads a zero-padded value such as 08 as octal.
        SIZE=$(( 10#$size_raw ))
        if (( SIZE < 1 )); then arg_error 'N must be greater than zero'; fi
    elif [[ -n "$SNAPSHOT_PATH" ]]; then
        # A ten-row snapshot makes a near-useless diff: anything that grew from
        # outside the top ten is invisible. Default to the whole set.
        SIZE=0
    fi

    case "$UNIT" in
        auto|K|M|G) ;;
        *) arg_error "unknown unit: $UNIT (expected auto, K, M, or G)" ;;
    esac

    case "$SORT_BY" in
        rss|swap|ksm) ;;
        pss)
            if (( ! WITH_PSS )); then
                arg_error '--sort pss requires --pss'
            fi
            ;;
        *) arg_error "unknown sort column: $SORT_BY (expected rss, pss, swap, or ksm)" ;;
    esac

    if [[ "$MODE" == 'diff' ]]; then
        if [[ -n "$SNAPSHOT_PATH" ]]; then
            arg_error '--diff and --snapshot cannot be combined'
        fi
        if [[ "$OUTPUT_FORMAT" == 'tsv' ]]; then
            arg_error '--diff does not support --tsv'
        fi
        return 0
    fi

    # ksm_stat arrived in Linux 6.1. Without it every KSM figure is zero and
    # sorting on the column returns an arbitrary set of processes.
    if [[ "$SORT_BY" == 'ksm' && ! -r /proc/self/ksm_stat ]]; then
        die 'kernel does not expose /proc/<pid>/ksm_stat; --sort ksm is unavailable'
    fi

    if (( WITH_PSS )) && [[ ! -r /proc/self/smaps_rollup ]]; then
        die 'kernel does not expose /proc/<pid>/smaps_rollup; --pss is unavailable'
    fi

    if (( WITH_OOM_LOG )); then
        command -v journalctl >/dev/null || die '--oom-log requires journalctl'
    fi
}

check_dependencies() {
    local cmd
    for cmd in awk sort date; do
        command -v "$cmd" >/dev/null || die "required command not found: $cmd"
    done
    if [[ -n "$SNAPSHOT_PATH" ]]; then
        command -v mktemp >/dev/null || die 'required command not found: mktemp'
    fi
}

# --- system context --------------------------------------------------------
read_meminfo() {
    local key value _
    while read -r key value _; do
        case "$key" in
            MemTotal:)     MEM_TOTAL_KB="$value" ;;
            MemAvailable:) MEM_AVAILABLE_KB="$value"; break ;;
        esac
    done < /proc/meminfo || log_warn 'could not read /proc/meminfo'
    if [[ ! "$MEM_TOTAL_KB" =~ ^[0-9]+$ ]]; then MEM_TOTAL_KB=0; fi
    if [[ ! "$MEM_AVAILABLE_KB" =~ ^[0-9]+$ ]]; then MEM_AVAILABLE_KB=0; fi
    return 0
}

read_hostname() {
    read -r HOST_NAME 2>/dev/null < /proc/sys/kernel/hostname || HOST_NAME='unknown'
    if [[ -z "$HOST_NAME" ]]; then HOST_NAME='unknown'; fi
    return 0
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
    local key value _ swap_seen=0
    _rss=''
    _swap=0
    while read -r key value _; do
        case "$key" in
            VmRSS:)  _rss="$value" ;;
            VmSwap:) _swap="$value"; swap_seen=1 ;;
        esac
        # Both fields sit in the first third of a ~55-line file; stop there
        # rather than scanning the remainder once per process on the host.
        if [[ -n "$_rss" ]] && (( swap_seen )); then break; fi
    done 2>/dev/null < "/proc/$1/status" || return 1
    if [[ -z "$_rss" ]]; then return 1; fi
    return 0
}

read_ksm() {
    local key value _
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

read_pss() {
    local key value _
    # -1 is the "not collected" sentinel, distinct from a genuine zero.
    _pss=-1
    if (( ! WITH_PSS )); then return 0; fi
    _pss=0
    # The permission check happens on read, not on stat, so an unreadable
    # rollup surfaces here rather than at the -r test.
    while read -r key value _; do
        if [[ "$key" == 'Pss:' ]]; then
            _pss="$value"
            break
        fi
    done 2>/dev/null < "/proc/$1/smaps_rollup" || _pss=0
    if [[ ! "$_pss" =~ ^[0-9]+$ ]]; then _pss=0; fi
    return 0
}

read_oom() {
    _oom=0
    read -r _oom 2>/dev/null < "/proc/$1/oom_score" || _oom=0
    if [[ ! "$_oom" =~ ^[0-9]+$ ]]; then _oom=0; fi
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
        read_pss "$pid"
        read_oom "$pid"

        RECORDS+=(
            "${_rss}"$'\t'"${_swap}"$'\t'"${_ksm}"$'\t'"${_name}"$'\t'"${_pss}"$'\t'"${_oom}"
        )
    done
}

# --- reporting -------------------------------------------------------------
sort_column_index() {
    case "$SORT_BY" in
        rss)  printf '1\n' ;;
        swap) printf '2\n' ;;
        ksm)  printf '3\n' ;;
        pss)  printf '5\n' ;;
    esac
}

# Emits every aggregated record, sorted, one per line, in raw units. This is
# the TSV contract and the table's input; the two must not diverge.
aggregate_sorted() {
    local sort_column
    sort_column="$(sort_column_index)"

    printf '%s\n' "${RECORDS[@]}" \
    | awk -F '\t' '
        function basename(path,   n, parts) {
            n = split(path, parts, "/")
            return parts[n]
        }
        # Key on the basename, not the raw path: /usr/bin/python3 and
        # /usr/local/bin/python3 belong in one bucket, not two rows that
        # both render as "python3" and neither of which is the total.
        {
            key = basename($4)
            rss[key]  += $1
            swap[key] += $2
            ksm[key]  += $3

            # PSS sums correctly across processes — that is the point of it —
            # but the -1 sentinel must not be added into a total.
            if ($5 < 0) no_pss[key] = 1; else pss[key] += $5

            # oom_score is a 0-1000 ranking, not a quantity. Summing it would
            # be meaningless; the group is as exposed as its worst member.
            if ($6 > oom[key]) oom[key] = $6
        }
        # %.0f, not %d: a KSM byte total can exceed a 32-bit int, and bare
        # %s would let CONVFMT emit 8.38861e+06, which sort -n cannot compare.
        END {
            for (name in rss)
                printf "%.0f\t%.0f\t%.0f\t%s\t%.0f\t%.0f\n",
                       rss[name], swap[name], ksm[name], name,
                       (no_pss[name] ? -1 : pss[name]), oom[name]
        }
      ' \
    | LC_ALL=C sort -t $'\t' \
          -k"${sort_column},${sort_column}"nr -k4,4
}

# Shared by every table-producing path so one change to the unit logic cannot
# leave the diff and the report disagreeing.
readonly AWK_FMT_LIB='
function fmt(kib,   neg, a, s) {
    neg = (kib < 0)
    a = neg ? -kib : kib
    if (unit == "K")      s = sprintf("%.0fK", a)
    else if (unit == "M") s = sprintf("%.0fM", a / 1024)
    else if (unit == "G") s = sprintf("%.1fG", a / 1048576)
    else if (a >= 1048576) s = sprintf("%.1fG", a / 1048576)
    else if (a >= 1024)    s = sprintf("%.0fM", a / 1024)
    else                   s = sprintf("%.0fK", a)
    return neg ? "-" s : s
}
'

print_context() {
    local shown="$1"
    local total_desc='unknown' avail_desc='unknown' pct='?'

    if (( MEM_TOTAL_KB > 0 )); then
        total_desc="$(awk -v unit="$UNIT" -v k="$MEM_TOTAL_KB" \
            "$AWK_FMT_LIB"' BEGIN { print fmt(k) }')"
        avail_desc="$(awk -v unit="$UNIT" -v k="$MEM_AVAILABLE_KB" \
            "$AWK_FMT_LIB"' BEGIN { print fmt(k) }')"
        pct="$(awk -v a="$MEM_AVAILABLE_KB" -v t="$MEM_TOTAL_KB" \
            'BEGIN { printf "%.1f", (a * 100) / t }')"
    fi

    printf '%s %s on %s — %s total, %s available (%s%% free) — showing %d command names\n' \
        "$SCRIPT_NAME" "$VERSION" "$HOST_NAME" \
        "$total_desc" "$avail_desc" "$pct" "$shown"
}

print_table() {
    if (( SHOW_HEADER )); then print_context "$#"; fi

    if (( $# == 0 )); then return 0; fi

    printf '%s\n' "$@" \
    | awk -F '\t' \
        -v unit="$UNIT" \
        -v with_pss="$WITH_PSS" \
        -v mem_total="$MEM_TOTAL_KB" \
        -v show_header="$SHOW_HEADER" \
        "$AWK_FMT_LIB"'
        BEGIN {
            row = with_pss \
                ? "%-26s %9s %7s %9s %9s %9s %5s\n" \
                : "%-26s %9s %7s %9s %9s %5s\n"
            if (show_header) {
                if (with_pss)
                    printf row, "NAME", "RSS", "%MEM", "PSS", "SWAP", "KSM", "OOM"
                else
                    printf row, "NAME", "RSS", "%MEM", "SWAP", "KSM", "OOM"
            }
        }
        {
            name = $4
            if (length(name) > 25)
                name = substr(name, 1, 25) "..."

            pct = (mem_total > 0) ? sprintf("%.1f", ($1 * 100) / mem_total) : "-"

            # status reports VmRSS, VmSwap, and Pss in kB; ksm_stat reports
            # profit in bytes, so it is normalised before formatting.
            if (with_pss)
                printf row, name, fmt($1), pct, fmt($5), fmt($2), fmt($3 / 1024), $6
            else
                printf row, name, fmt($1), pct, fmt($2), fmt($3 / 1024), $6
        }
      ' || die 'failed to format output'
}

print_tsv() {
    if (( SHOW_HEADER )); then printf '%s\n' "$TSV_HEADER"; fi
    # Rows already carry the TSV contract; no reformatting, no rounding.
    if (( $# )); then printf '%s\n' "$@"; fi
}

print_oom_history() {
    local out
    # grep exits 1 on no match, which pipefail would make fatal; an absent
    # journal or a host with no OOM history is a normal, quiet result.
    out="$(journalctl -k --since '-7 days' --no-pager -o short-iso 2>/dev/null \
        | grep -E 'Killed process|Out of memory' \
        | tail -n 5)" || out=''

    printf '\n'
    if [[ -z "$out" ]]; then
        printf 'No kernel OOM kills in the last 7 days.\n'
        return 0
    fi
    printf 'Recent kernel OOM kills (last 7 days, most recent last):\n'
    printf '%s\n' "$out"
}

# --- snapshot --------------------------------------------------------------
write_snapshot() {
    local dest="$SNAPSHOT_PATH"
    local dir tmp

    dir="${dest%/*}"
    if [[ "$dir" == "$dest" ]]; then dir='.'; fi
    if [[ ! -d "$dir" ]]; then die "snapshot directory does not exist: $dir"; fi

    # Same directory, so the rename below stays within one filesystem and is
    # therefore atomic — a concurrent reader sees the old file or the new one.
    tmp="$(mktemp -- "${dest}.XXXXXX")" || die "cannot create temp file beside $dest"

    if ! {
        printf '# topmem-snapshot %s\n' "$SNAPSHOT_FORMAT"
        printf '# generated: %s\n' "$(date --iso-8601=seconds)"
        printf '# host: %s\n' "$HOST_NAME"
        printf '# sort: %s\n' "$SORT_BY"
        printf '# mem_total_kb: %s\n' "$MEM_TOTAL_KB"
        printf '%s\n' "$TSV_HEADER"
        if (( $# )); then printf '%s\n' "$@"; fi
    } >"$tmp"; then
        rm -f -- "${tmp:?}"
        die "failed to write snapshot; $dest left unchanged"
    fi

    # umask 077 above would otherwise leave this 0600.
    chmod 0644 -- "$tmp" || { rm -f -- "${tmp:?}"; die "cannot set mode on $tmp"; }
    mv -f -- "$tmp" "$dest" || { rm -f -- "${tmp:?}"; die "cannot install $dest"; }

    log_info "snapshot written: $dest ($# command names)"
}

# --- diff ------------------------------------------------------------------
require_snapshot() {
    local f="$1" first=''
    if [[ ! -e "$f" ]]; then die "no such file: $f"; fi
    if [[ ! -f "$f" ]]; then die "not a regular file: $f"; fi
    if [[ ! -r "$f" ]]; then die "not readable: $f"; fi

    IFS= read -r first < "$f" || die "cannot read: $f"
    if [[ "$first" != "# topmem-snapshot $SNAPSHOT_FORMAT" ]]; then
        die "not a topmem snapshot of format $SNAPSHOT_FORMAT: $f"
    fi
}

# awk has no -- separator for file operands: it reads a bare operand containing
# '=' as a var assignment and one beginning with '-' as an option. A ./ prefix
# makes a relative path unambiguous; an absolute path already is one.
awk_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf './%s\n' "$1" ;;
    esac
}

snapshot_meta() {
    local f="$1" want="$2" line body key
    while IFS= read -r line; do
        case "$line" in
            '#'*) ;;
            *) break ;;
        esac
        body="${line#\# }"
        key="${body%%:*}"
        if [[ "$key" == "$want" ]]; then
            printf '%s\n' "${body#*: }"
            return 0
        fi
    done < "$f"
    printf 'unknown\n'
    return 0
}

run_diff() {
    local sort_column old_when new_when output old_operand new_operand
    local -a rows=()

    require_snapshot "$DIFF_OLD"
    require_snapshot "$DIFF_NEW"

    sort_column="$(sort_column_index)"
    old_operand="$(awk_path "$DIFF_OLD")"
    new_operand="$(awk_path "$DIFF_NEW")"
    old_when="$(snapshot_meta "$DIFF_OLD" 'generated')"
    new_when="$(snapshot_meta "$DIFF_NEW" 'generated')"

    output="$(
        awk -F '\t' -v col="$sort_column" '
            /^#/            { next }
            $1 == "rss_kb"  { next }
            NR == FNR       { old[$4] = $col; seen[$4] = 1; next }
            {
                new[$4] = $col
                seen[$4] = 1
            }
            END {
                for (n in seen) {
                    o = (n in old) ? old[n] : 0
                    v = (n in new) ? new[n] : 0
                    printf "%.0f\t%.0f\t%.0f\t%s\n", v - o, o, v, n
                }
            }
          ' "$old_operand" "$new_operand" \
        | LC_ALL=C sort -t $'\t' -k1,1nr -k4,4
    )" || die 'failed to compare snapshots'

    if [[ -n "$output" ]]; then mapfile -t -n "$SIZE" rows <<< "$output"; fi

    if (( SHOW_HEADER )); then
        printf '%s %s on %s — %s change between snapshots\n' \
            "$SCRIPT_NAME" "$VERSION" "$HOST_NAME" "$SORT_BY"
        printf '  before: %s (%s)\n' "$old_when" "$DIFF_OLD"
        printf '  after:  %s (%s)\n' "$new_when" "$DIFF_NEW"
    fi

    if (( ${#rows[@]} == 0 )); then
        printf 'No command names found in either snapshot.\n'
        return 0
    fi

    printf '%s\n' "${rows[@]}" \
    | awk -F '\t' -v unit="$UNIT" -v show_header="$SHOW_HEADER" \
        "$AWK_FMT_LIB"'
        BEGIN {
            row = "%-26s %11s %11s %11s\n"
            if (show_header) printf row, "NAME", "BEFORE", "AFTER", "CHANGE"
        }
        {
            name = $4
            if (length(name) > 25)
                name = substr(name, 1, 25) "..."
            change = ($1 > 0) ? "+" fmt($1) : fmt($1)
            printf row, name, fmt($2), fmt($3), change
        }
      ' || die 'failed to format diff output'
}

# --- report ----------------------------------------------------------------
report() {
    local sorted
    local -a rows=()

    sorted="$(aggregate_sorted)" || die 'failed to aggregate or sort process records'

    # mapfile -n applies the top-N limit in place of head(1). head closing the
    # pipe would SIGPIPE the upstream sort, and pipefail would report that as a
    # script failure on an otherwise normal run. -n 0 reads every row.
    if [[ -n "$sorted" ]]; then mapfile -t -n "$SIZE" rows <<< "$sorted"; fi

    if [[ -n "$SNAPSHOT_PATH" ]]; then
        write_snapshot "${rows[@]}"
        return 0
    fi

    case "$OUTPUT_FORMAT" in
        table) print_table "${rows[@]}" ;;
        tsv)   print_tsv   "${rows[@]}" ;;
    esac

    if (( WITH_OOM_LOG )); then print_oom_history; fi
}

# --- main ------------------------------------------------------------------
main() {
    parse_arguments "$@"
    check_dependencies
    read_hostname

    if [[ "$MODE" == 'diff' ]]; then
        run_diff
        return 0
    fi

    read_meminfo
    collect_processes

    if (( ${#RECORDS[@]} == 0 )); then die 'no readable processes found in /proc'; fi

    report
}

main "$@"
