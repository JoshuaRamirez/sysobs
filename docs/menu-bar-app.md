# The menu-bar app

`app/` is SysObs.app: sysobs in the macOS menu bar, the standard look of DeskHub
and Teams Watch (a plain menu under a status item, a Settings window with tabs,
no Dock icon). Bundle id `com.redjay.sysobs`, version 0.1.0, macOS 14.4+.

```sh
bash app/build.sh            # build, bundle, ad-hoc sign, install ~/Applications/SysObs.app (not launched)
bash app/build.sh --launch   # ...and open it
cd app && swift test         # SysObsCore on fixture data; no live calls
```

## What the menu shows

- **Snapshot** — when the latest full snapshot was taken (relative and clock)
  and how long it took; under it the machine-wide picture: load averages,
  process and thread counts, CPU user / sys / idle, memory used of total with
  wired and compressed, swap used of total.
- **Top by CPU** and **Top by Memory** — the heaviest processes of the newest
  light sample (five by default), with when it was sampled and its load.
- **Started and Exited, Last Hour** — the newest ten process starts and exits,
  each with its parent and, for an exit, how long it lived.
- **Take a Snapshot Now** — runs `sysobs snapshot --json`; the outcome (taken,
  skipped because another sysobs held the store lock, failed) is shown under
  the actions. **Refresh**, **Settings…**, **Quit**.

The symbol in the bar is `cpu` with the one-minute load beside it. The status
item's autosave name is `sysobs`, so its place in the bar is kept.

## How it reads sysobs

The app is a reader. It never writes to the store and never takes
`.store.lock`; the one writer it ever starts is `sysobs snapshot` itself, when
asked. Every refresh (30 s by default):

| what | from | why not the command |
|---|---|---|
| latest snapshot | the last row of `tables/snapshot.csv` | `show --json` streams the 1 GB `process` table for its row counts: 2 min under load |
| machine-wide picture | the last row of `tables/host_sample.csv` | same |
| top by CPU / memory | `sysobs light --since 1h --by cpu\|rss -n N --json`, newest tick | `top --json` streams `process` and `process_sample`: ~1 min under load |
| starts and exits | the tail of the newest two `spool/procwatch-<hour>.ndjson` | `events --json --no-ingest` streams `argv` (0.9 GB): 19 s; the spool is fresher, within 2 s |

The two tables are read from their tail only (16 KB), the spool files from
theirs (512 KB each); a line still being written, or one shifted a column, is
skipped. When there is no spool at all (procwatch has never run on this store)
the app falls back to `sysobs events --since 1h -n 10 --json --no-ingest`,
which reads the stored `process_event` rows, up to a snapshot behind.

`sysobs` is run through `/usr/bin/env` from `~/Developer/sysobs/bin/sysobs`
or `~/.local/bin/sysobs`, whichever exists first, with `/opt/homebrew/bin`
ahead on PATH so `python3` is Homebrew's and not the Xcode stub. The store is
`$SYSOBS_HOME`, else `$XDG_STATE_HOME/sysobs`, else `~/.local/state/sysobs`,
as in `bin/sysobs`.

## Settings

`~/.config/sysobs/menu-bar.json`: `refresh_seconds` (default 30, 5–3600) and
`top_count` (default 5, 1–20). Out-of-range values are clamped. The Status tab
shows the command and store in use, the last snapshot and sample, and which
source the events came from.

## Layout

```
app/Package.swift                 SysObsCore (library), SysObs (app), SysObsCoreTests
app/Sources/SysObsCore/           Paths, Settings, CSV, Snapshot (SnapshotRow, HostPicture, ShowPayload),
                                  LightSample, ProcessEvent + Spool, SnapshotResult, Format, TimeFormat
app/Sources/SysObs/               SysObsApp (status item, Settings scene), AppModel, MenuView, SettingsView
app/Tests/SysObsCoreTests/        fixtures cut from a real store and real --json output
app/build.sh, app/make-icon.sh    the bundle, the icon
```

All parsing and every phrase the menu shows live in SysObsCore and are tested
on fixtures; the app target only reads files, runs sysobs and draws.
