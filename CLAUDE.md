# sysobs — working notes for Claude

A single-file Python 3 CLI that records what this machine is doing into a
normalized, referentially-intact log. `README.md` is the user-facing document
and is kept accurate; this file is the part that is easy to get wrong.

## Shape

```
bin/sysobs        the entire tool — one file, stdlib only, no third-party imports
docs/gen_diagrams.py   regenerates docs/sysobs-diagrams.html (six logical diagram families)
contrib/*.plist   launchd agent templates, __HOME__ substituted at install
README.md         what it does and why
```

Data lives outside the repo, in `$SYSOBS_HOME` (default
`~/.local/state/sysobs`). The repo holds no data and never should.

## The rules that matter

**The schema is the single source of truth.** `SCHEMA` in `bin/sysobs` drives
the CSV headers, the SQLite DDL *and* the integrity checker. Never hand-write
a header, a `CREATE TABLE`, or a check that names columns directly — add it to
the schema declaration and let all three follow. A composite parent a single
column cannot express goes in `FACT_PARENT`.

**`sysobs selftest` is the contract, not a smoke test.** 75 fixtures, no
privileges, no network. Run it after every change. It pins the output formats
the tool does not own (`ps`, `top`, `lsof`, `netstat`, `ioreg`) and causes the
store's failure modes deliberately — dangling FK, orphaned fact, column-shifted
row, duplicate re-ingest, replayed spool, in-place edit that must reach the
mirror. If a change is right and selftest disagrees, selftest is probably
describing a real regression.

**The store has exactly one writer.** The 5-minute `local.sysobs` agent
is it, and it holds `.store.lock` while writing. Dimension tables are rewritten
whole on every flush, so a second concurrent writer silently drops the first
one's rows. Consequences:

- `procwatch` does *not* write tables. It appends NDJSON to `spool/` and the
  snapshot job folds it in.
- Before any in-place migration of existing CSVs, **stop the agent** or write
  through the tool under the lock. A previous migration ran while the agent
  was executing the same script mid-edit and produced a few hundred
  column-shifted rows.

**The SQLite mirror is derived and may be deleted at any time.** It is never
the answer to "is the log current" — the CSVs are. `sysobs query` fingerprints
each table (size + sha1 of the prefix) and syncs before answering; `--no-sync`
opts out. Reporting a number read from a stale mirror has already happened
once and was wrong.

## Traps that have already cost time

- **IORegistry reports battery current as unsigned 64-bit.** A pack
  discharging reads `18446744073709551583`, not `-33`. Every power field needs
  `_signed()`, not just the obvious ones — `SystemLoad` overflowed SQLite and
  aborted a whole mirror build.
- **`lsof` and `netstat` spell endpoints four different ways**
  (`*:443`, `1.2.3.4:443`, `[::1]:5000`, `127.0.0.1.48793`). `split_hostport`
  handles all four, and a bare `192.168.1.10` must not split into host
  `192.168.1` + port `10`. `netstat` also truncates long IPv6, so socket byte
  counts join on `(pid, local_port, remote_port)` — never on address text.
- **SQLite column affinity is not automatic.** Everything defaults to TEXT and
  then `MIN(elapsed_s)` compares lexicographically — a 43-hour process sorts
  "younger" than a 2-minute one. `REAL_COLS` / `INT_COLS` / `sql_type()`.
  `fd` stays TEXT on purpose: `cwd` and `txt` are valid fds.
- **`libproc` is denied for processes you do not own**, so `csw`, `faults` and
  friends are empty for root processes. Filtering on them silently excludes
  every daemon. `cpu_time_s` comes from `ps` and exists for everything.
- **The parent must be bound when a child is first seen, not when it exits.**
  At exit the parent may already be gone — often in the same tick — and that
  orphan case is the one worth recording. Backfilling at render time makes
  `sysobs events` look right while every SQL question about exits loses
  attribution.

## Conventions

- `--json` on every reading command; exit `0` ok, `1` finding, `2` usage.
- A gap is recorded, never implied: every collector writes a `collector_run`
  row with status, duration, rows and a message. Degrading is fine; lying is
  not.
- `--geo online` is off by default and transmits **only `public`** addresses.
  Private, loopback and link-local are never sent. Do not change that default.
- Commits: Conventional Commits with an emoji, e.g.
  `🐛 fix(sysobs): …`, `✨ feat(sysobs): …`, `📝 docs(sysobs): …`.

## Diagrams

`python3 docs/gen_diagrams.py` regenerates `docs/sysobs-diagrams.html` — six
logical diagram families (pathways, swimlanes, one class model, use cases,
five activity diagrams, component containment). Coordinates are computed and
element names are read from the same `SCHEMA` dict, for the same reason the
DDL is: a hand-maintained diagram drifts, and a drifted diagram is worse than
none.
