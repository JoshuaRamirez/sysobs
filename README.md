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

```
sysobs snapshot                 # capture
sysobs show                     # read the latest one back
sysobs top --by net             # heaviest processes
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
tables/<table>.csv     one file per table, append-only for facts
sysobs.sqlite          built on demand by `sysobs db`
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
| `ip_address` | an address, with offline scope, optional rDNS and optional geo |
| `port` | a protocol/port pair, named from `/etc/services` |

**Facts** are written once per snapshot and point at the dimensions.

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
- `last_seen` never precedes `first_seen`
- every snapshot has the rows that make it usable

`sysobs db` loads the same data into SQLite with `PRAGMA foreign_keys = ON` and
then runs `PRAGMA foreign_key_check`, so the database independently confirms
what `verify` claims.

Collectors enforce this at write time rather than repairing it afterwards: a
`nettop`, `lsof` or `netstat` row whose pid is not in this snapshot (processes
start and exit between collectors) is dropped, and the drop is *counted in
`collector_run`* rather than silently discarded.

`sysobs prune --days N --go` drops old snapshots and then garbage-collects
dimension rows nothing points at any more, in dependency order, so the store
never passes through a state where a reference dangles.

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

## Selftest

`sysobs selftest` pins the parsers for the output formats this tool does not
own — `ps` elapsed and CPU times, `top` size suffixes, `lsof` and `netstat`
endpoint spellings, `netstat -anv` rows whose process name contains spaces —
and round-trips a small store through `verify` and SQLite, deliberately
breaking a foreign key and an orphaned fact to confirm both are caught.
