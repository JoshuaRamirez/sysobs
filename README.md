# sysobs

[![ci](https://github.com/JoshuaRamirez/sysobs/actions/workflows/ci.yml/badge.svg)](https://github.com/JoshuaRamirez/sysobs/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-12%2B-lightgrey)
![python](https://img.shields.io/badge/python-3.9%2B-blue)
![dependencies: none](https://img.shields.io/badge/dependencies-none-success)

A normalized, referentially-intact log of what this machine is doing.

One `sysobs snapshot` records, for a single instant: every running process with
its CPU, RAM, thread and context-switch numbers; every open file; every socket
with its ports, both IP addresses and the bytes that moved over it; disk usage
per volume and throughput per device; network volume per interface; and the
machine-wide CPU, memory, paging and swap picture.

Nothing is written twice. A file path, an IP address, a protocol/port pair, a
volume, an interface and an executable each live exactly once in a dimension
table and are referenced by id from the per-snapshot fact rows. Two hundred
processes with the same dylib open produce one `file` row and two hundred
`process_file` edges.

Two recorders share that store. `snapshot` answers *what is true right now*;
`procwatch` answers *what happened in between* — every process start and exit,
with the parent that launched it.

```
sysobs snapshot                 # capture an instant
sysobs show                     # read the latest one back
sysobs top --by net             # heaviest processes
sysobs events --since 1h        # what started and stopped since
sysobs verify                   # every reference resolves?
sysobs db && sysobs query "..." # SQL, with the FKs enforced by SQLite
```

## What it collects, and where it goes

**Nowhere.** sysobs makes no network connection of its own. The store is local,
owner-readable only (`0700`/`0600`), and nothing is uploaded, phoned home or
shared.

The one opt-in exception is `--geo online`, which resolves **public** IP
addresses through `ip-api.com`. Private, loopback and link-local addresses are
never sent, the installed agents never pass the flag, and `--rdns` uses only
your system resolver.

Be equally clear about the other direction: **this is a surveillance tool
pointed at your own machine.** It records the full command line of every
process it can see, and command lines are where secrets leak — `mysql
-pPASSWORD`, an API key passed as a flag, a token in a `curl`. There is no
redaction. Treat `$SYSOBS_HOME` the way you would treat a credentials file,
and never paste raw store contents into a bug report.

See [SECURITY.md](SECURITY.md) for the full statement.

## Install

macOS, python3 ≥ 3.9, no third-party packages. `sysobs` is one file.

```sh
git clone https://github.com/JoshuaRamirez/sysobs.git
cd sysobs
./install.sh
```

That puts `sysobs` on your PATH and loads three launchd agents — snapshot,
procwatch, prune. The installer runs `selftest` first and refuses to install
if it fails, rather than scheduling a job that breaks every five minutes.
`./install.sh --dry-run` prints what it would do and changes nothing.

```sh
./install.sh --interval 60          # snapshot every minute instead of five
./install.sh --store /Volumes/big/sysobs
./install.sh --no-agents            # the command only, no background jobs
./install.sh --copy                 # copy the script instead of symlinking
```

To remove it:

```sh
./uninstall.sh                      # agents and command go; DATA STAYS
./uninstall.sh --purge              # ...and delete the store (asks first)
```

Without `--purge` this is reversible: re-run `./install.sh` and collection
resumes on the same store, with referential integrity intact.

Data lands in `$SYSOBS_HOME`, default `~/.local/state/sysobs`:

```
tables/<table>.csv       one file per table, append-only for facts
spool/procwatch-*.ndjson process events, hourly, awaiting ingestion
spool/offsets.json       how far each spool file has been folded in
.store.lock              held by whoever is writing the tables
sysobs.sqlite            built on demand by `sysobs db`
```

## The schema

Nine dimensions, thirteen facts. Mostly a **star** — a dimension is one hop
from the fact that references it — with one deliberately **snowflaked** arm:

```
command ──▶ file ──▶ volume
```

An executable is a file, and a file lives on a volume. Flattening that chain
would repeat a volume's UUID and mount point on every one of ~18k distinct
file rows, so it stays normalized and costs one extra join on the rare query
that needs to get from a command to the disk it came off. Every other
dimension hangs directly off a fact.

`sysobs schema` prints it; `sysobs schema --ddl` prints the SQL. Two kinds of
table:

**Dimensions** are deduped across all time and carry `first_seen` / `last_seen`.

| table | what it identifies |
|---|---|
| `host` | the machine (hostname, hw uuid, model, cpu, ram, os) |
| `volume` | a mounted filesystem — *the* location a file path lands on |
| `disk_device` | a block device as `iostat` names it |
| `interface` | a network interface |
| `file` | a file path, split into directory / basename / extension, bound to its `volume` |
| `command` | an executable image, normalized onto its `file` |
| `argv` | a full command line, stored once however many processes ran it |
| `ip_address` | an address, with offline scope, optional rDNS and optional geo |
| `port` | a protocol/port pair, named from `/etc/services` |

**Facts** point at the dimensions. Most are written once per snapshot;
`process_event` is written once per *event*, whenever it happened.

| table | grain |
|---|---|
| `snapshot` | one capture run |
| `collector_run` | what each collector managed to see |
| `host_sample` | machine-wide reading |
| `process` | process identity (pid, ppid, uid, argv, start time) |
| `process_sample` | cpu / ram / threads / faults / context switches for one pid |
| `process_net_sample` | bytes in and out per pid (`nettop`) |
| `process_file` | pid → fd → file location |
| `socket` | pid → fd → protocol, both addresses, both ports, state, bytes |
| `process_event` | one process start or exit, with the command, the command line and the parent it was launched from |
| `volume_sample` | disk usage per volume |
| `disk_io_sample` | throughput per device |
| `interface_sample` | packets and bytes per interface |
| `power_sample` | adapter watts vs system demand, headroom, battery current, SoC |

Three views make the joins unnecessary for ordinary questions: `v_process`,
`v_connection`, `v_open_file`.

## Power

`power_sample` exists because the first real investigation with this tool found
a 16-core, 128 GB MacBook Pro clamped to 27 W by a 30 W USB-C charger while it
was asking for 100 W. Every other table looked healthy — 12% CPU, 89% memory
free, no fd or socket leaks — and the load average was 222.

Two details that make the reading trustworthy:

- the IORegistry reports battery current as an **unsigned** 64-bit word, so a
  pack *discharging while plugged in* — the exact state worth catching — reads
  as `18446744073709551583`, not `-33`. `sysobs` undoes the wrap.
- `PowerTelemetryData.BatteryPower` disagreed with reality (it claimed
  `-522 mW` while the pack charged at `+6110 mA`), so the `power_capped`
  verdict is derived from `InstantAmperage`, which matched observation in both
  the starved and the recovered state.

A capped machine announces itself in `collector_run`:

```
~ power: POWER CAPPED: pd charger supplies 30W, machine is asking for 27.4W
```

## Referential integrity

The schema is the single source of truth. The CSV headers, the SQLite DDL and
the integrity checker are all generated from it, so they cannot drift apart.

`sysobs verify` checks, without needing a database:

- headers on disk match the schema
- primary keys are unique and fully populated
- every declared foreign key resolves (an empty value is an allowed absence —
  a listening socket has no peer address — a non-empty value that points at
  nothing is a defect)
- composite parents: every `process_sample`, `process_file`, `socket` and
  `process_net_sample` row has its `process` row *in the same snapshot*
- a column declared numeric parses as a number. Width-correct rows can still be
  shifted one column to the left — which is what an appending writer and a
  file that disagree about the schema produce — and every key and foreign-key
  check above passes while the data means nothing
- `last_seen` never precedes `first_seen`
- every snapshot has the rows that make it usable

`sysobs db` loads the same data into SQLite with `PRAGMA foreign_keys = ON` and
then runs `PRAGMA foreign_key_check`, so the database independently confirms
what `verify` claims.

The mirror is incremental but not credulous. Loading only unseen rows is right
for an append and silently wrong for a *correction*: a mirror that can never
catch up is worse than one that is merely stale. Each table's byte size and the
sha1 of its prefix up to that size are recorded in `_mirror_source`; an
identical prefix proves nothing before that offset changed, so the table was
appended to. A differing prefix means a row was edited and that table reloads
in full. `sysobs query` syncs first unless given `--no-sync`.

Collectors enforce this at write time rather than repairing it afterwards: a
`nettop`, `lsof` or `netstat` row whose pid is not in this snapshot (processes
start and exit between collectors) is dropped, and the drop is *counted in
`collector_run`* rather than silently discarded.

`sysobs prune --days N [--event-days N] --go` drops old snapshots — and
process events on their own, shorter clock — then garbage-collects dimension
rows nothing points at any more, in dependency order, so the store never
passes through a state where a reference dangles.

## Between snapshots: process starts and exits

A snapshot every five minutes cannot see a process that lived for three
seconds — so it cannot answer *"what just opened a Java icon, and who launched
it?"*. `procwatch` closes that gap: it polls the pid list ten times a second
(~0.1 ms a pass, ~0.3% of one core, 30–50 MB resident) and records each
**start** and **exit** with pid, ppid, uid, executable, command line, the
**parent it was launched from**, and how long it lived.

```sh
sysobs procwatch                       # foreground
sysobs events --since 1h               # what started and stopped
sysobs events --match java             # ...matching a command, argv or parent
sysobs events --event exit -n 20
sysobs events --since 2h --json        # --no-ingest to read only what is stored
```

Install it as an always-on agent:

`./install.sh` already did this. It runs as `local.sysobs-procwatch`, with
`KeepAlive`, so it comes back after a crash or a reboot.

Four properties worth knowing:

- **It is not the store's writer.** Dimension tables are rewritten whole on
  every flush, so a second writer would silently drop the first one's rows.
  `procwatch` appends to `spool/procwatch-<hour>.ndjson`; the snapshot job
  folds the spool into `process_event` under `.store.lock`, resuming from a
  byte offset and deduping on `event_id`. A stopped procwatch degrades to
  *events arrive late*, never to *the store is corrupt*. `sysobs events`
  ingests too, so reading never waits for the next snapshot.
- **Identity is (pid, start time)**, because pids are reused and start times
  are not. "exit" means *left the process table*, so a zombie's lifetime
  includes the wait for its parent to reap it.
- **The parent is bound when the child is first seen, not when it exits.** By
  exit time the parent may be gone — often in the same tick — and that orphan
  case is exactly the one worth recording. Resolving it at render time instead
  would make `sysobs events` look right while every SQL question about exits
  silently lost attribution.
- **Both the spool and the table are bounded**, because this recorder produces
  hundreds of rows a minute against the snapshot job's one every five.
  Spool files rotate hourly and are deleted once fully ingested and a few
  hours old — the spool is a transfer buffer, not an archive.
  `sysobs prune --days 14 --event-days 3 --go` then keeps events on their own,
  much shorter clock than snapshots, and garbage-collects the `argv` and
  `command` rows nothing points at any more.

### What it actually costs

Measured over seven hours on a busy workstation (Chrome, a Node toolchain,
several Claude Code sessions):

| | rate | at rest |
|---|---|---|
| events | 200–800 a minute, ~115k in 7 h | `process_event.csv` ≈ 2.7 MB/hour |
| command lines | ~18k distinct, averaging 732 characters | `argv.csv` ≈ 2 MB/hour |
| spool | ~12 MB/hour raw NDJSON | deleted 6 h after ingestion |

Normalizing command lines into the `argv` dimension cut the fact rows by more
than half — but be honest about the limit: **`argv` does not saturate.** 18,424
rows held 18,424 distinct strings, because Chrome helpers and shell wrappers
embed pids, ports and handles that differ on every launch. Dedup pays for
`sleep 0.2` and for login shells, not for Chrome. Budget roughly **5 MB an
hour**, or ~350 MB standing at three-day retention.

### The blind spot, stated rather than hidden

A process shorter than the poll interval can be missed, so every row records
the interval that saw it in `source` (`procwatch-100ms`). A real `java
-version` lives ~20 ms and is a coin flip; anything that draws a window lives
far longer and is always caught. Exact capture of every exec would need
`/usr/bin/eslogger`, which requires a root LaunchDaemon and a Full Disk Access
grant — a different trust decision, not just a bigger number.

## What it cannot see, and says so

Every collector writes a `collector_run` row with its status, duration, row
count and a message. Unprivileged, that means:

- `libproc` task info (threads, faults, context switches, exact CPU ns) is
  available only for your own processes; other rows carry `source=ps` and leave
  those columns empty rather than zero
- `lsof` shows sockets and files of your own processes only
- `--files own` (the default) enumerates open files for your uid; `--files all`
  asks for every process and needs root to actually get it

Run under `sudo` for full coverage. A gap is always recorded, never implied.

## Location

Two kinds, both normalized:

- **file location** — `file.directory`, `file.basename`, `file.extension` and
  `file.volume_id` → `volume.mount_point`, resolved by longest-prefix match
  against the live mount table captured in the same snapshot.
- **network location** — `ip_address.scope` classifies every address offline
  (`loopback`, `link-local`, `private`, `cgnat`, `multicast`, `reserved`,
  `public`). `--rdns` adds reverse DNS through the system resolver. `--geo
  online` is **off by default** and, when asked for, sends only `public`
  addresses to ip-api.com — private, loopback and link-local addresses are
  never transmitted.

## Running it continuously

```sh
sysobs watch --interval 300            # foreground
```

Or leave it to launchd — `./install.sh` installs it as `local.sysobs`,
rendered from `contrib/launchd/snapshot.plist.in`:

```sh
./install.sh --interval 300            # the default
```

A snapshot with `--files own` costs roughly 20–40 s and ~4 MB of CSV; with
`--files none`, a few seconds and ~250 KB. Pair it with `sysobs prune`.

Three agents make up the running system, and they are deliberately separable —
each is useful without the others:

| agent | template | what it does |
|---|---|---|
| `local.sysobs` | `contrib/launchd/snapshot.plist.in` | a snapshot every 5 min, and the **only writer** of the tables — it also folds in procwatch's spool |
| `local.sysobs-procwatch` | `contrib/launchd/procwatch.plist.in` | the always-on start/exit recorder; `KeepAlive`, so it comes back |
| `local.sysobs-prune` | `contrib/launchd/prune.plist.in` | weekly `prune --days 14 --go` |

Install any subset by hand if you want fewer: render the template you want,
`launchctl bootstrap` it, and skip the rest. `./install.sh --no-agents`
installs the executable alone.

If `svc` is on the machine, the
installer also writes descriptors from `contrib/svc/*.json.in`, so
`svc show sysobs`, `svc logs sysobs-procwatch` and `svc health` work. That is
local convenience, not a dependency — it is skipped silently when `svc` is
absent.

## What it costs, and rolling retention

Measured on an M-series Mac, 5-minute cadence with `procwatch` running:

| | |
|---|---|
| one snapshot, `--files none` | **~4.0 s median, 6.4 s p95** — about **1.3% of one core** |
| `procwatch`, continuously | **~0.9% of one core, 18 MB RSS** |
| store growth | **~135 MB/day** of CSV at 5-min cadence |
| marginal cost of one snapshot | **~370 KB** of fact rows |
| the SQLite mirror | derived, rebuildable, not part of the cost |

CPU is not the constraint. **Disk is**, and it scales with cadence:

| cadence | CSV per day |
|---|---|
| 1 hour | ~11 MB |
| 5 min *(default)* | ~135 MB |
| 1 min | ~675 MB |

Which is why retention is tiered rather than flat. Keep full detail for a
rolling window, then thin the history to something you can afford to keep
for a year:

```sh
# every snapshot for the last 24h, then one per hour out to 90 days
sysobs prune --days 90 --full-days 1 --thin-to 1h --go
```

Dry run first — without `--go` it only tells you what it would do:

```
214 snapshot(s) dropped (keeping every snapshot for 1.0d,
                         then one per 1h out to 90d), 302 kept
```

Thinning drops whole snapshots and then garbage-collects any dimension row
nothing references any more, so the store shrinks **without** the history
developing holes: `sysobs verify` is clean on the other side. `--event-days`
retains process events separately, since they arrive hundreds of times a
minute.

The installed prune agent runs this weekly, and the defaults are
`--keep-days 90 --full-days 1 --thin-to 1h`. Change them at install time:

```sh
./install.sh --interval 60 --full-days 2 --thin-to 15m --keep-days 365
```

That combination — a snapshot every minute, full detail for 48 hours, then
one every 15 minutes for a year — is about **14 GB of fact rows**, against
roughly **195 GB** for the same cadence kept unthinned.

Size it from the **marginal** cost, not the average: a snapshot adds about
**370 KB** of fact rows. Dimensions are shared and grow sub-linearly (35 MB
here across 517 snapshots), and `process_event` is retained on its own clock
via `--event-days`, so it does not scale with cadence at all.

## Known asymmetry

`process.argv` is still stored inline, one copy per process per snapshot, which
is why `process.csv` is the largest table in the store (81 MB against
`process_event.csv`'s 22 MB for five times as many rows). The `argv` dimension that
`process_event` uses was added later and `process` has not been migrated onto
it. Doing so is a schema change plus a rewrite of the existing CSV, worth doing
deliberately rather than opportunistically — the last in-place migration here
was performed while the 5-minute agent was running the same script and wrote a
few hundred column-shifted rows. Stop the agent first, or write through the
tool under `.store.lock`.

## Diagrams

`docs/sysobs-diagrams.html` is a single self-contained page — no network, no
CDN — holding six logical views of the system:

| | |
|---|---|
| communication pathways | every channel, typed by colour **and** glyph so it survives greyscale; probe pathways are double-headed because this tool instruments nothing and every reading is a question asked of a stock binary |
| swimlanes | five flow orders over one set of nine lanes — the lanes never change, only the order they are visited |
| class model | every element that appears in any other diagram, once |
| use cases | `«include»` (always) kept distinct from `«extend»` (only when asked) |
| activity | the five behaviours where a naive implementation loses data |
| component containment | structure with the connections deliberately removed |

```sh
python3 docs/gen_diagrams.py      # regenerate
open docs/sysobs-diagrams.html
```

Generated rather than drawn, and the element names are read from the same
`SCHEMA` dict the CSV headers and the SQL DDL come from — for the same reason.
A diagram maintained by hand drifts from the thing it describes, and a drifted
diagram is worse than none.

## Selftest

`sysobs selftest` runs 75 fixtures in a temporary store, no privileges and no
network. They cover the places this tool breaks quietly rather than the places
it is obviously right:

- the output formats it does not own — `ps` elapsed and CPU times, `top` size
  suffixes, `lsof` and `netstat` endpoint spellings, `netstat -anv` rows whose
  process name contains spaces, and the unsigned 64-bit wrap in battery current
- the kernel calls procwatch depends on: `KERN_PROCARGS2` argv parsing, and
  that ppid, uid and start time are readable for a **root-owned** process, so a
  daemon's children are not invisible
- procwatch against a real process: spawn one that lives 0.35 s, confirm the
  start *and* the exit are caught, that they share one identity, and that the
  parent is recorded
- the store's failure modes, by causing them: a dangling foreign key, an
  orphaned fact, a row shifted one column left, a re-ingest that must not
  duplicate, a spool replayed with its offset deleted, an in-place edit that
  must reach the mirror without `--rebuild`, and a pure append that must still
  load incrementally

Run it after every change; it is the contract, not a smoke test.

## Contributing

Bug reports and patches welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The
short version: `sysobs selftest` is the contract, a parsing fix needs a fixture
built from the real string you saw, and the schema is a single source of truth
rather than three places to remember.

Security issues go through [private reporting](SECURITY.md), not public issues.

## License

[MIT](LICENSE) © 2026 Joshua Ramirez
