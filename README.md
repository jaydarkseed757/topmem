# topmem

Report the processes consuming the most memory on a Linux host.

`topmem.sh` walks `/proc`, aggregates resident memory, swap, and KSM profit by
command name, and prints the top N — as a table for a human at a terminal, or as
tab-separated records for anything else. It reads `/proc` and writes to stdout;
it changes nothing on disk and modifies no process state.

Unlike `ps` or `top`, results are **grouped by command name**, so twelve browser
renderers or forty Apache workers appear as a single row carrying their combined
footprint. That is usually the number you want when answering "what is eating
this box."

## Requirements

- Linux with a mounted `procfs`
- bash 4.4 or newer (RHEL 8 ships 4.4, RHEL 9 ships 5.1)
- `awk`, `sort`, `date` — all part of a base install

No external packages, no network access, no compilation.

The KSM column additionally requires Linux 6.1 or newer; see
[Limitations](#limitations).

## Installation

```bash
install -m 0755 topmem.sh /usr/local/bin/topmem.sh
```

Or run it in place:

```bash
chmod +x topmem.sh
./topmem.sh
```

## Usage

```
topmem.sh [OPTIONS] [N]
```

### Arguments

| Argument | Description |
|---|---|
| `N` | Maximum number of entries to display. Positive integer. Default `10`. |

### Options

| Option | Description |
|---|---|
| `-s`, `--sort <TYPE>` | Column to sort by: `rss`, `swap`, or `ksm`. Default `rss`. |
| `--sort=<TYPE>` | Equivalent to the above. |
| `--tsv` | Emit tab-separated records with raw units instead of the table. |
| `--no-header` | Suppress the header line in either format. |
| `-a`, `--all` | Show every command name. Cannot be combined with `N`. |
| `-h`, `--help` | Print help and exit 0. |
| `--` | End of options. A following operand is treated as `N`. |

`--all` and an explicit `N` are rejected together rather than resolved by
precedence — a caller who wrote both had one of the two in mind, and guessing
wrong silently truncates their data.

### Examples

```bash
topmem.sh                                  # top 10 by resident memory
topmem.sh 20                               # top 20 by resident memory
topmem.sh --sort swap                      # top 10 by swap usage
topmem.sh -s ksm 25                        # top 25 by KSM profit
topmem.sh --tsv --all --no-header          # every row, machine-readable
```

## Table output

```
MEMORY    Top 10 processes                    SWAP      KSM
2914M     qemu-kvm                            0M        512M
1103M     java                                48M       0M
622M      postgres                            0M        0M
```

| Column | Source | Meaning |
|---|---|---|
| `MEMORY` | `VmRSS` in `/proc/<pid>/status` | Resident set size, summed across processes sharing a name |
| `Top N processes` | first field of `/proc/<pid>/cmdline` | Command name, `basename`d |
| `SWAP` | `VmSwap` in `/proc/<pid>/status` | Swapped-out pages |
| `KSM` | `ksm_process_profit` in `/proc/<pid>/ksm_stat` | Memory saved by kernel same-page merging |

All figures are rounded to whole mebibytes, so anything under about half a MiB
displays as `0M`. Command names longer than 25 characters are truncated with a
trailing `...`. The header reports the number of rows actually printed, not the
requested `N`: asking for 500 on a host with 90 distinct command names prints
`Top 90 processes`.

The table format is for reading, not for parsing. Column positions, padding,
rounding, and truncation are all subject to change. Use `--tsv` for anything
programmatic.

## TSV output

```
$ topmem.sh --tsv 3
rss_kb	swap_kb	ksm_bytes	name
2983936	0	537133056	qemu-kvm
1129472	49152	0	java
636928	0	0	postgres
```

| Field | Position | Unit | Notes |
|---|---|---|---|
| `rss_kb` | 1 | kibibytes | As reported by the kernel, unrounded |
| `swap_kb` | 2 | kibibytes | As reported by the kernel, unrounded |
| `ksm_bytes` | 3 | bytes | Signed — can be negative when a process is a net loss for KSM |
| `name` | 4 | — | Full command basename, never truncated |

Three properties make this the mode to build against:

- **Raw units.** No rounding to MiB, so a 400 KiB process is distinguishable
  from a genuinely idle one. The consumer decides on presentation.
- **Untruncated names.** No 25-character cutoff.
- **Stable field order.** New columns will only ever be appended. A parser
  written against positions 1–4 keeps working.

Note the unit difference between fields 1–2 and field 3: the kernel reports
`VmRSS` and `VmSwap` in kB but `ksm_process_profit` in bytes, and the TSV passes
both through as-is rather than silently normalising. A KSM figure that looks
1024× off is the classic symptom of dividing them the same way.

Fields are separated by a single tab, which is what `awk`, `cut`, and `sort` all
expect by default:

```bash
# every command over 1 GiB resident
topmem.sh --tsv --all | awk -F'\t' 'NR > 1 && $1 > 1048576 { print $4 }'

# snapshot for later comparison
topmem.sh --tsv --all --no-header > "/var/tmp/topmem.$(date +%s).tsv"
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime failure — unreadable `/proc`, aggregation or sort failure, unsupported kernel for the requested sort |
| `2` | Usage error — bad option, missing operand, non-numeric or zero `N`, `--all` combined with `N` |

All diagnostics go to stderr with a timestamp, script name, PID, and severity, so
stdout stays clean and pipeable in both output modes.

## Limitations

**KSM requires a recent kernel.** `/proc/<pid>/ksm_stat` was introduced in Linux
6.1. RHEL 8 ships 4.18 and RHEL 9 ships 5.14, so on either the KSM column reads
zero for every process. `--sort ksm` refuses to run on such a kernel rather than
returning an arbitrarily ordered list; the other two sorts work normally and the
column is simply always zero.

**Non-root runs may be incomplete.** Reading another user's `/proc/<pid>/cmdline`
and `status` is normally permitted, but a host mounting `procfs` with `hidepid=1`
or `hidepid=2` will hide other users' processes. Those processes are skipped
silently. Run as root for a full picture.

**The snapshot is not atomic.** Processes start and exit while `/proc` is being
walked. A process that disappears mid-scan is skipped rather than reported as an
error.

**Grouping is by name, not by cgroup, user, or path.** Processes are bucketed by
the basename of the first `cmdline` field, so `/usr/bin/python3` and
`/usr/local/bin/python3` sum into a single `python3` row — as do two entirely
unrelated Python services. That is a deliberate trade for readability. Where the
distinction matters, `ps` with an explicit `-o` format or a per-cgroup view via
`systemd-cgtop` is the better tool.

**Shared pages are counted repeatedly.** RSS includes shared libraries and
copy-on-write pages, so summing across processes double-counts memory that
physically exists once. The totals are useful for ranking, not for accounting;
`smem` with its PSS column is the right tool if you need figures that add up.

## Implementation notes

The script runs under `set -euo pipefail`. The top-N limit is applied with
`mapfile -n` rather than `head`, deliberately: `head` closing the pipe would
`SIGPIPE` the upstream `sort`, which `pipefail` would then surface as a script
failure on an otherwise normal run. The aggregation pipeline is checked
explicitly, so a genuine failure — `sort` running out of temp space, say — is
reported with the script name and PID rather than as a bare error from a
subprocess.

Both output modes share a single aggregation and sort stage that emits exactly
the TSV format. The table is a formatting pass over those same rows, which keeps
the two from drifting apart.

Ordering is descending on the selected column, with ties broken ascending on
command name under `LC_ALL=C`. Two runs against an unchanged workload produce
byte-identical output, so snapshots diff cleanly.

Per-process data is read with bash builtins rather than `tr`, `head`, and
per-field `awk` calls, and the scan of `/proc/<pid>/status` stops once both
fields of interest have been seen. On a host with several hundred processes this
removes roughly five forks per PID.
