# Contributing to sysobs

Small project, few rules, but the rules it has are load-bearing.

## Before you start

```sh
./bin/sysobs selftest
```

That is the contract. 75 fixtures covering the parts that parse someone
else's output format — `ps`, `lsof`, `netstat`, `nettop`, `ioreg` — which is
exactly where this tool breaks quietly when macOS changes its mind about a
format. **A change that does not keep selftest green is not ready**, and the
installer will refuse to install it.

No dependencies to install. sysobs is one Python 3 file and uses the standard
library only. That is deliberate: it has to run on a machine that is already
in trouble, where `pip install` is not a thing you want to be doing.

## The four things that are easy to get wrong

Read `CLAUDE.md` before a non-trivial change. It is not a second README — it
records the traps. In short:

1. **The schema is the single source of truth.** CSV headers, the SQLite DDL
   and the integrity checker are all generated from one `SCHEMA` dict. Add a
   column there, not in three places.
2. **The store has exactly one writer.** Dimension tables are rewritten whole
   on every flush, so a second writer silently drops the first one's rows.
   Stop the snapshot agent before any in-place migration.
3. **The SQLite mirror is derived.** It is never the answer to "is the log
   current". Rebuild it; do not repair it.
4. **Degradation must be visible.** Every value carries a `source`. A
   collector that could not read something records that it could not, rather
   than recording a zero. Silent zeros are worse than gaps, because a gap
   prompts a question and a zero ends one.

## Style

- Comments explain **why**, not what. If a line needs a comment to say what it
  does, rewrite the line.
- Match the surrounding code. It has a voice; keep it.
- Conventional Commits with an emoji, matching `git log`:
  `✨ feat(scope):`, `🐛 fix(scope):`, `📝 docs(scope):`, `🔒 fix(scope):`,
  `♻️ refactor(scope):`, `🔖 chore(release):`.
- The commit body says what was wrong and why the fix is the right shape.
  Several of the commits here are worth reading as examples.

## Pull requests

- One concern per PR.
- Include what you observed, not just what you changed — this is an
  observability tool, and "here is the output before and after" is the most
  useful thing you can put in a PR description.
- New parsing behaviour needs a fixture. If you fixed a format this tool
  misread, add the real string you saw to `selftest` so it cannot regress.
- CI runs on `macos-latest`. It runs selftest, a full install → snapshot →
  verify → db → query → uninstall round trip, lints every rendered plist and
  asserts the data store survives an uninstall.

## Platform

macOS only, and not apologetically — sysobs reads `libproc` through `ctypes`,
`ioreg`, `nettop`, `vm_stat` and IOKit power data. A Linux port would be a
different collector behind the same schema, and would be welcome as such, but
it is not a matter of relaxing an `if` statement.

## Reporting something sensitive

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
