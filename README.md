# sysobs

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

## Install

```sh
ln -s ~/Developer/sysobs/bin/sysobs ~/.local/bin/sysobs
sysobs selftest
```

Data lands in `$SYSOBS_HOME`, default `~/.local/state/sysobs`:

```
tables/<table>.csv       one file per table, append-only for facts
spool/procwatch-*.ndjson process events, hourly, awaiting ingestion
spool/offsets.json       how far each spool file has been folded in
.store.lock              held by whoever is writing the tables
sysobs.sqlite            built on demand by `sysobs db`
```

## The schema

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

```sh
sed "s|__HOME__|$HOME|g" contrib/local.sysobs-procwatch.plist \
  > ~/Library/LaunchAgents/local.sysobs-procwatch.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.sysobs-procwatch.plist
```

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

Or install the launchd agent template (`contrib/local.sysobs.plist`):

```sh
sed "s|__HOME__|$HOME|g" contrib/local.sysobs.plist \
  > ~/Library/LaunchAgents/local.sysobs.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.sysobs.plist
```

A snapshot with `--files own` costs roughly 20–40 s and ~4 MB of CSV; with
`--files none`, a few seconds and ~250 KB. Pair it with `sysobs prune`.

Three agents make up the running system, and they are deliberately separable —
each is useful without the others:

| agent | plist | what it does |
|---|---|---|
| `local.sysobs` | `contrib/local.sysobs.plist` | a snapshot every 5 min, and the **only writer** of the tables — it also folds in procwatch's spool |
| `local.sysobs-procwatch` | `contrib/local.sysobs-procwatch.plist` | the always-on start/exit recorder; `KeepAlive`, so it comes back |
| `local.sysobs-prune` | — | weekly `prune --days 14 --event-days 3 --go` |

On this machine they are registered with `svc`, so `svc show sysobs`,
`svc logs sysobs-procwatch` and `svc health` work; that is local convenience,
not a dependency.

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

`sysobs selftest` runs 71 fixtures in a temporary store, no privileges and no
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
