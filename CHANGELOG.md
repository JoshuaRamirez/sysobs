# Changelog

Notable changes. Format loosely follows [Keep a Changelog](https://keepachangelog.com);
this project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- **A menu-bar app**, `app/` (SysObs.app, `com.redjay.sysobs`, 0.1.0): the
  latest snapshot and the machine-wide picture (load, CPU, memory, swap), the
  top processes by CPU and by memory from the newest light sample, the last
  hour's process starts and exits, "Take a Snapshot Now", and a Settings window
  for the refresh interval (30 s) and the list length (5). The standard look of
  DeskHub and Teams Watch: an NSStatusItem (autosave name `sysobs`) with a
  SwiftUI menu, LSUIElement, ad-hoc signed, installed to `~/Applications` by
  `app/build.sh` (never launched unless `--launch`). It reads the tails of
  `snapshot.csv`, `host_sample.csv` and the procwatch spool, and runs
  `sysobs light --json`; `show`, `top` and `events` stream gigabyte tables and
  took 19 s to 2 min under load. The parsing and every phrase shown live in
  the `SysObsCore` library, 35 XCTest checks on fixtures cut from a real store.
  [docs/menu-bar-app.md](docs/menu-bar-app.md).

## [0.3.0] — 2026-10-20

It keeps sampling under heavy load (the Desk #m1020-1547-c8d1). Baseline
`ca90e92`; release notes: [docs/releases/v0.3.0.md](docs/releases/v0.3.0.md).
Tests: 7/7 heavy-load tests; selftest 107 checks, all passing at load 77, with the procwatch fixture (a 0.35 s child at 50 ms polling) missing its child when run at background QoS over load ~150.

### Added

- **Light sample.** One `ps` call per tick (pid, ppid, %cpu, rss, etime,
  command), written at once to `light/light-<day>.ndjson.gz` before the full
  snapshot asks for the lock. `sysobs light --since 1h | --at 13:50 [--by cpu|rss]`.
- **Priority under load.** Over 2x the cores of one-minute load, the sampler,
  its snapshots and procwatch clear the background clamp, go to
  user-interactive thread QoS and tier 0, and run their children under
  `taskpolicy -t 0 -l 0`. `SYSOBS_BOOST=0` off, `SYSOBS_BOOST_FACTOR` the threshold.
  The full snapshot runs in background while the machine is calm and comes
  out of it when the load crosses the threshold, checked every 10 s.
- The sampler and procwatch start at `ProcessType Interactive` (base priority
  31). A launchd job without it starts at 20, and nothing an unprivileged
  process does at run time lifts that (measured: thread QoS, taskpolicy tiers,
  the Darwin role).
- `tests/test_sample_under_load.py`: lock held, cut-off snapshot, stubbed
  load, procwatch under substrate.

### Changed

- **`watch` is the scheduled sampler**: a light sample every tick, the full
  snapshot in a child unless the last is still running. Default interval 300.
- **The sampler and procwatch run under substrate** (`sub enable`) when `sub`
  is installed; launchd agents otherwise. Every job names an absolute
  interpreter (Homebrew python3 by default, `--python`): under launchd,
  `python3` was the Xcode 3.9 stub. No more `Nice 10` / `Background` on the
  sampler.
- `install.sh` moves superseded agents aside (`SYSOBS_ASIDE`) instead of
  deleting them; the selftest preflight is opt-in (`--selftest`).
- `list`, `show`, `top` stream the fact tables; `events` reads only its window
  from the end of `process_event` and only the argv rows it names.

### Fixed

- **A snapshot waited 120 s on the store lock and then died** with
  `TimeoutError`. It now skips its write at once (`LockBusy`), as does the
  ingest in `events`.
- selftest's procwatch fixture crashed with `IndexError` when a pegged
  machine starved it past the 0.35 s child's life; it reports a failure now.
  The `cmd_snapshot` fixture's light sample stays in its temp store.

## [0.2.0] — 2026-09-20

The release that made it installable by someone other than its author.

### Security

- **The data store was world-readable.** It is created `0700`/`0600` now.
  `argv.csv` holds the full command line of every process on the machine, and
  command lines routinely carry secrets, so on a shared machine any local
  account could read them. `sysobs verify` repairs an existing store and
  reports that it had to, rather than fixing it silently. **If you ran an
  earlier version, run `sysobs verify` once.**

### Added

- **Tiered retention.** `sysobs prune --days 90 --full-days 1 --thin-to 1h`
  keeps every snapshot inside a rolling detail window, then one per bucket out
  to the horizon, then nothing. Flat `--days` still works unchanged. Makes a
  1-minute cadence affordable: full detail for 48h and one per 15 min for a
  year costs ~14 GB instead of ~195 GB.
- `install.sh` — idempotent installer. Runs `selftest` first and refuses to
  install if it fails, renders the launchd units from templates, and writes
  `svc` descriptors when `svc` is present. `--dry-run`, `--prefix`, `--store`,
  `--interval`, `--poll`, `--keep-days`, `--label-prefix`, `--copy`,
  `--no-agents`, `--no-svc`.
- `uninstall.sh` — removes exactly what the installer added. **Keeps the data
  store by default**; `--purge` deletes it and asks for typed confirmation.
  `--all-labels` cleans up older installs, `--no-agents`, `--force`.
- `contrib/launchd/*.plist.in` and `contrib/svc/*.json.in` — templates,
  rendered at install time.
- CI on `macos-latest`: selftest, a full install → snapshot → verify → db →
  query → uninstall round trip, `plutil -lint` on every rendered plist, and an
  assertion that the store survives an uninstall.
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `LICENSE` (MIT),
  issue and PR templates.
- Four selftest fixtures for store permissions. 75 checks total, up from 71.

### Changed

- launchd labels `local.sysobs*` → `local.sysobs*`, configurable with
  `--label-prefix`. An existing install is migrated in place; the store is not
  touched.
- Agents now carry `SYSOBS_HOME` explicitly instead of relying on the default.
- README leads with install/uninstall and states plainly what is collected and
  where it goes.

### Fixed

- **`sysobs db` read the store without the lock.** It reads table by table while
  the single writer rewrites dimension tables whole, so a flush landing mid-read
  produced a torn view and the mirror rejected `process_event` rows referencing
  `argv` ids it had never seen — against CSVs that verified clean. The read now
  happens under the lock; the slow SQLite load does not.
- **A single bad row discarded its whole table.** `executemany` is one
  statement, so one dangling reference rolled back 300k sound rows with it. It
  now retries row by row and reports the count rejected.
- **Incremental sync was slower than a full rebuild** — 2150 s against 13 s.
  Dimension rows are refreshed on every flush to move `last_seen`, and
  `INSERT OR REPLACE` is a DELETE plus an INSERT; deleting a parent makes SQLite
  prove nothing references it — a full scan of a 320k-row table, 40k times over.
  Dimensions are now upserted with `ON CONFLICT DO UPDATE`, which edits in place
  and never deletes a parent. **Incremental: >600 s -> 5.6 s.**

  Indexing every foreign-key column was tried as part of the same fix and
  **reverted after measurement**: interleaved A/B runs under identical load put
  4 indexes and 30 indexes within noise of each other on the incremental path
  (26-28 s both, on a loaded machine), while the 30 cost 103 MB of database and
  ~86 s of rebuild. Removing the DELETE was the whole fix; the indexes were
  cargo. The four that serve the views remain.

- An agent belongs to the install **whose binary it runs**. Uninstalling a
  throwaway `--prefix` used to boot out the real agents, because the label
  prefix matched even though the executable did not. Both scripts now compare
  `ProgramArguments[0]`, and the installer only supersedes a previous agent
  that writes the *same* store.

## [0.1.0]

Initial single-file collector: dimensional CSV store, referential integrity
checker, SQLite mirror, process start/exit recorder, power telemetry, prune.
