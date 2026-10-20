# sysobs features (v0.3.0)

## Recording

- `snapshot`: one normalized snapshot (host, volumes, power, host sample, disk
  io, interfaces, processes, per-process network, sockets, open files) into a
  star schema of CSVs; a light sample first.
- `watch`: the scheduled sampler; a light sample every tick, a full snapshot in
  a child when none is running.
- `procwatch`: every process start and exit, polled, spooled to NDJSON, folded
  in by the snapshot.
- Light samples: one `ps` per tick, gzip NDJSON beside the store, 14 days kept.
- Priority under load: over 2x cores of load, user-interactive QoS, tier 0,
  children under `taskpolicy -t 0 -l 0`.

## Reading

- `light`: the light samples by window or nearest a time, heaviest first.
- `list`, `show`, `top`: snapshots, one snapshot, heaviest processes in one.
- `events`: starts and exits in a window.
- `db`, `query`: the SQLite mirror and SQL against it.
- `verify`, `schema`: referential integrity, the schema.

## Keeping

- `prune`: tiered retention that keeps references intact.
- `install.sh` / `uninstall.sh`: substrate jobs or launchd agents, svc
  descriptors, absolute interpreter.
- `selftest` and `tests/`: the behaviour contract.
