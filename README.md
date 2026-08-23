# topmem 1.0

Report the processes consuming the most memory on a Linux host — and, with
snapshots, show what is *growing*.

`topmem.sh` walks `/proc`, aggregates memory by command name, and prints the top
N as a table or as tab-separated records. It can write a snapshot for later
comparison and diff two snapshots to show change per command. It is read-only
against the system; the only file it writes is a snapshot you asked for.

Unlike `ps` or `top`, results are **grouped by command name**, so twelve browser
renderers or forty Apache workers appear as a single row carrying their combined
footprint. That is usually the number you want when answering "what is eating
this box."

## Requirements

- Linux with a mounted `procfs`
- bash 4.4 or newer (RHEL 8 ships 4.4, RHEL 9 ships 5.1)
- `awk`, `sort`, `date` — all part of a base install
- `mktemp` for `--snapshot`, `journalctl` for `--oom-log`

No external packages, no network access, no compilation, no privileges beyond
reading `/proc`.

Two columns depend on kernel version:

| Feature | Needs | RHEL 8 (4.18) | RHEL 9 (5.14) |
|---|---|---|---|
| `--pss` (`smaps_rollup`) | Linux 4.14+ | yes | yes |
| KSM column (`ksm_stat`) | Linux 6.1+ | no | no |

## Installation

```bash
install -m 0755 topmem.sh /usr/local/bin/topmem.sh
```

## Usage

```
topmem.sh [OPTIONS] [N]
topmem.sh --diff OLD_SNAPSHOT NEW_SNAPSHOT
```

| Option | Description |
|---|---|
| `-s`, `--sort <TYPE>` | Sort column: `rss`, `pss`, `swap`, `ksm`. Default `rss`. `pss` requires `--pss`. |
| `-u`, `--unit <UNIT>` | Size unit: `auto`, `K`, `M`, `G`. Default `auto`. |
| `--pss` | Collect proportional set size from `smaps_rollup`. |
| `--tsv` | Emit tab-separated records with raw units. |
| `--no-header` | Suppress header lines in either format. |
| `--oom-log` | Append recent kernel OOM kills from the journal. |
| `-a`, `--all` | Show every command name. Cannot be combined with `N`. |
| `--snapshot FILE` | Write results to `FILE` for later comparison. |
| `--diff OLD NEW` | Compare two snapshots and report change per command. |
| `-V`, `--version` | Print version and exit. |
| `-h`, `--help` | Print help and exit. |
| `--` | End of options. A following operand is treated as `N`. |

Long options also accept `--sort=rss`, `--unit=G`, `--snapshot=FILE`.

```bash
topmem.sh                                  # top 10 by resident memory
topmem.sh 20 --sort swap                   # top 20 by swap
topmem.sh --pss --sort pss                 # rank by proportional set size
topmem.sh --oom-log                        # add recent OOM kills
topmem.sh --tsv --all --no-header          # machine-readable, every row
topmem.sh --snapshot /var/tmp/mem.snap     # record for later
topmem.sh --diff old.snap new.snap         # what grew
```

## Table output

```
topmem.sh 1.0 on web01 — 15.6G total, 3.2G available (20.5% free) — showing 10 command names
NAME                             RSS    %MEM       PSS      SWAP       KSM   OOM
qemu-kvm                        2.8G    18.2      1.9G        0K      512M   134
java                            1.1G     7.0      983M       48M        0K    89
postgres                        622M     3.9      412M        0K        0K    41
```

The context line answers the question a raw byte count cannot: `2914M` means
something different on an 8 GB box than on a 512 GB one. `MemTotal` and
`MemAvailable` come from `/proc/meminfo`, and `%MEM` is each row's RSS as a
share of `MemTotal`.

| Column | Source | Aggregation |
|---|---|---|
| `NAME` | first field of `/proc/<pid>/cmdline`, `basename`d | grouping key |
| `RSS` | `VmRSS` in `/proc/<pid>/status` | sum |
| `%MEM` | `RSS` ÷ `MemTotal` | derived |
| `PSS` | `Pss` in `/proc/<pid>/smaps_rollup` | sum (only with `--pss`) |
| `SWAP` | `VmSwap` in `/proc/<pid>/status` | sum |
| `KSM` | `ksm_process_profit` in `/proc/<pid>/ksm_stat` | sum |
| `OOM` | `/proc/<pid>/oom_score` | **max**, not sum |

`oom_score` is a 0–1000 ranking, not a quantity — summing it would be
meaningless, so the group takes the score of its worst member. It is what the
kernel would reap next, which is often more actionable than raw size.

The `PSS` column appears only with `--pss`. Collecting it makes the kernel walk
page tables for every process, which is why it is opt-in rather than default;
`smaps_rollup` is nonetheless far cheaper than a full `smaps` walk, and it is the
figure that does *not* double-count shared pages.

The header reports the number of rows actually printed, not the requested `N`.

**The table format is for reading, not parsing.** Column positions, padding,
rounding, and truncation are all subject to change. Use `--tsv`.

### Units

`auto` (the default) picks per value: under 1 MiB renders as `K`, under 1 GiB as
`M`, above that as `G` with one decimal. `--unit K|M|G` forces one unit
throughout, which is what you want when eyeballing a column for relative size.

## TSV output

```
$ topmem.sh --tsv 3
rss_kb	swap_kb	ksm_bytes	name	pss_kb	oom_score
2983936	0	537133056	qemu-kvm	1998848	134
1129472	49152	0	java	1006592	89
636928	0	0	postgres	421888	41
```

| Field | Position | Unit | Notes |
|---|---|---|---|
| `rss_kb` | 1 | kibibytes | Unrounded |
| `swap_kb` | 2 | kibibytes | Unrounded |
| `ksm_bytes` | 3 | **bytes** | Signed — negative when a process is a net loss for KSM |
| `name` | 4 | — | Full command basename, never truncated |
| `pss_kb` | 5 | kibibytes | `-1` when `--pss` was not given, distinct from a genuine `0` |
| `oom_score` | 6 | — | Highest score in the group |

**Field positions are a compatibility promise.** New columns are only ever
appended, never inserted — which is why `name` sits at position 4 with numeric
fields on both sides rather than being tidied to the end. A parser written
against positions 1–4 in an earlier build keeps working.

Note the unit difference between fields 1–2 and field 3: the kernel reports
`VmRSS`, `VmSwap`, and `Pss` in kB but `ksm_process_profit` in bytes, and the TSV
passes both through as-is rather than silently normalising. A KSM figure that
looks 1024× off is the classic symptom of dividing them the same way.

```bash
# every command over 1 GiB resident
topmem.sh --tsv --all | awk -F'\t' 'NR > 1 && $1 > 1048576 { print $4 }'
```

## Snapshots and diff

A single reading tells you what is big. Two readings tell you what is leaking.

```bash
# hourly, from cron
topmem.sh --snapshot "/var/tmp/topmem.$(date +%%Y%%m%%d-%%H).snap"

# later
topmem.sh --diff /var/tmp/topmem.20260823-08.snap \
                 /var/tmp/topmem.20260823-16.snap
```

```
topmem.sh 1.0 on web01 — rss change between snapshots
  before: 2026-08-23T08:00:04-04:00 (/var/tmp/topmem.20260823-08.snap)
  after:  2026-08-23T16:00:03-04:00 (/var/tmp/topmem.20260823-16.snap)
NAME                            BEFORE       AFTER      CHANGE
java                              1.1G        3.4G       +2.3G
newcomer                            0K         10M        +10M
postgres                          622M        618M         -4M
```

Rows are sorted by change, descending, so growth is at the top. A command
present in only one snapshot is treated as zero in the other, which is how
`newcomer` above shows a full-size gain. `--diff` respects `--sort`, `--unit`,
`--no-header`, and `N`.

A snapshot file is the TSV records with a `#`-prefixed metadata header:

```
# topmem-snapshot 1
# generated: 2026-08-23T16:00:03-04:00
# host: web01
# sort: rss
# mem_total_kb: 16384000
rss_kb	swap_kb	ksm_bytes	name	pss_kb	oom_score
...
```

The first line is a format version. `--diff` refuses a file it does not
recognise rather than misreading the columns. `--tsv` output never carries these
comment lines; they exist only in snapshot files.

**`--snapshot` implies `--all`** unless you give `N` or `--all` explicitly. A
ten-row snapshot makes a near-useless diff — anything that grew from outside the
top ten is invisible.

Snapshots are written temp-file-then-rename within the destination directory, so
a concurrent reader sees either the old file or the new one, never a partial
write. They land mode 0644 regardless of the script's `umask 077`.

## OOM history

`--oom-log` appends the last five kernel OOM kills from the past seven days:

```
Recent kernel OOM kills (last 7 days, most recent last):
2026-08-21T03:14:22-0400 web01 kernel: Out of memory: Killed process 28114 (java)
```

Requires `journalctl`. A host with no OOM history says so rather than printing
nothing.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime failure — unreadable `/proc`, unsupported kernel for a requested feature, snapshot write failure, unrecognised snapshot format |
| `2` | Usage error — bad option, missing operand, invalid `N` or unit, mutually exclusive flags |

All diagnostics go to stderr with a timestamp, script name, PID, and severity, so
stdout stays clean and pipeable in every mode.

## Limitations

**KSM needs Linux 6.1.** RHEL 8 and RHEL 9 both predate it, so the KSM column
reads zero throughout. `--sort ksm` refuses to run rather than returning an
arbitrarily ordered list.

**`--diff` has no TSV mode.** The combination is rejected rather than silently
ignored. If you need machine-readable deltas today, snapshot to TSV and diff with
`join` or `awk`.

**Non-root runs may be incomplete.** `hidepid=1`/`hidepid=2` hides other users'
processes, and `smaps_rollup` requires `PTRACE_MODE_READ` — a process whose PSS
cannot be read contributes 0 rather than failing the run. Run as root for a full
picture.

**The snapshot is not atomic.** Processes start and exit while `/proc` is walked.
A process that disappears mid-scan is skipped rather than reported as an error.

**Grouping is by name, not by cgroup, user, or path.** `/usr/bin/python3` and
`/usr/local/bin/python3` sum into a single `python3` row — as do two entirely
unrelated Python services. That is a deliberate trade for readability. Where the
distinction matters, `ps -o` or `systemd-cgtop` is the better tool.

**RSS double-counts shared pages.** Shared libraries and copy-on-write pages are
counted once per process, so RSS totals overstate physical memory. Use `--pss`
for figures that add up.

## Implementation notes

The script runs under `set -euo pipefail`, sanitises `PATH`, and sets `umask 077`
for cron and systemd use. The top-N limit is applied with `mapfile -n` rather
than `head`: `head` closing the pipe would `SIGPIPE` the upstream `sort`, which
`pipefail` would then surface as a script failure on an otherwise normal run.

Every table-producing path shares one `awk` unit-formatting function, so the
report and the diff cannot drift apart on rounding. Both output modes share a
single aggregation and sort stage that emits exactly the TSV format.

Ordering is descending on the selected column, with ties broken ascending on
command name under `LC_ALL=C`, so two runs against an unchanged workload produce
byte-identical output and snapshots diff cleanly.

Per-process data is read with bash builtins rather than `tr`, `head`, and
per-field `awk` calls, and each `/proc` file is abandoned as soon as the fields
of interest have been seen.
