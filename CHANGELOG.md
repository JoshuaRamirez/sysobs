# Changelog

Notable changes. Format loosely follows [Keep a Changelog](https://keepachangelog.com);
this project uses [Semantic Versioning](https://semver.org).

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
  year costs ~1.3 GB instead of ~240 GB.
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

- An agent belongs to the install **whose binary it runs**. Uninstalling a
  throwaway `--prefix` used to boot out the real agents, because the label
  prefix matched even though the executable did not. Both scripts now compare
  `ProgramArguments[0]`, and the installer only supersedes a previous agent
  that writes the *same* store.

## [0.1.0]

Initial single-file collector: dimensional CSV store, referential integrity
checker, SQLite mirror, process start/exit recorder, power telemetry, prune.
