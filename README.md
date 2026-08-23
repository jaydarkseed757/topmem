# topmem

Report the processes consuming the most memory on a Linux host.

`topmem.sh` walks `/proc`, aggregates resident memory, swap, and KSM profit by
command name, and prints the top N. It reads `/proc` and writes a table to
stdout — it changes nothing on disk and modifies no process state.

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
| `N` | Number of entries to display. Positive integer. Default `10`. |

### Options

| Option | Description |
|---|---|
| `-s`, `--sort <TYPE>` | Column to sort by: `rss`, `swap`, or `ksm`. Default `rss`. |
| `--sort=<TYPE>` | Equivalent to the above. |
| `-h`, `--help` | Print help and exit 0. |
| `--` | End of options. A following operand is treated as `N`. |

### Examples

```bash
topmem.sh                 # top 10 by resident memory
topmem.sh 20              # top 20 by resident memory
topmem.sh --sort swap     # top 10 by swap usage
topmem.sh -s ksm 25       # top 25 by KSM profit
```

## Output

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
trailing `...`.

`VmRSS` and `VmSwap` are reported by the kernel in kB; `ksm_process_profit` is
reported in bytes. The script converts each with the correct divisor — a KSM
figure that looks 1024× too small is the classic symptom of getting this wrong.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime failure — unreadable `/proc`, unsupported kernel for the requested sort |
| `2` | Usage error — bad option, missing operand, non-numeric or zero `N` |

All diagnostics go to stderr with a timestamp, script name, PID, and severity, so
the table on stdout stays clean and pipeable:

```bash
topmem.sh 50 | grep -i postgres
```

## Limitations

**KSM requires a recent kernel.** `/proc/<pid>/ksm_stat` was introduced in Linux
6.1. RHEL 8 ships 4.18 and RHEL 9 ships 5.14, so on either the KSM column reads
`0M` for every process. `--sort ksm` refuses to run on such a kernel rather than
returning an arbitrarily ordered list; the other two sorts work normally and the
column is simply always zero.

**Non-root runs may be incomplete.** Reading another user's `/proc/<pid>/cmdline`
and `status` is normally permitted, but a host mounting `procfs` with `hidepid=1`
or `hidepid=2` will hide other users' processes. Those processes are skipped
silently. Run as root for a full picture.

**The snapshot is not atomic.** Processes start and exit while `/proc` is being
walked. A process that disappears mid-scan is skipped rather than reported as an
error.

**Grouping is by command name, not by cgroup or user.** Two unrelated programs
that happen to share a basename — say, two different `python3` services — are
summed into one row. Where that matters, `ps` with an explicit `-o` format is the
better tool.

**Shared pages are counted repeatedly.** RSS includes shared libraries and
copy-on-write pages, so summing across processes double-counts memory that
physically exists once. The totals are useful for ranking, not for accounting;
`smem` with its PSS column is the right tool if you need figures that add up.

## Notes

The script runs under `set -euo pipefail`. Truncation to N rows happens inside
`awk` rather than via `head`, deliberately: `head` closing the pipe would
`SIGPIPE` the upstream `sort`, which `pipefail` would then surface as a script
failure on an otherwise normal run.

Per-process data is read with bash builtins rather than `tr`, `head`, and
per-field `awk` calls. On a host with several hundred processes this removes
roughly five forks per PID, which is the difference between a script that returns
promptly and one that noticeably does not.
