# Security

## What sysobs collects

Be clear-eyed about this before you run it anywhere: **sysobs is a
surveillance tool pointed at your own machine.** The store contains

- every process, its pid, ppid, uid and **full command line**
- every process start and exit, with the parent that launched it
- local and remote socket addresses and ports
- mounted volumes, network interfaces, and power/battery telemetry

**Command lines are the sensitive part.** Secrets end up on command lines all
the time — `mysql -pPASSWORD`, an API key passed as a flag, a token in a
`curl` invocation. sysobs records them verbatim, and it records them for every
process it can see, including other users' processes where the OS permits.

There is no redaction. Treat `$SYSOBS_HOME` as you would treat a credentials
file.

## How it is protected

The store is created `0700`, files `0600` — owner only. `sysobs verify` checks
this on every run, repairs it if something loosened it, and **tells you** it
had to, rather than fixing it silently. Versions before 0.2.0 created a
world-readable store; if you ran one, run `sysobs verify` once.

macOS itself sets the ceiling on what can be collected: `libproc` denies
per-process detail for processes you do not own, and sysobs records that
denial as a degraded `source` rather than pretending the value is zero.

## Where data goes

**Nowhere, by default.** sysobs makes no network connection of its own.

There is exactly one opt-in exception, `--geo online`, which looks up
geolocation for **public** IP addresses through `ip-api.com`. Private,
loopback and link-local addresses are never sent. It is off unless you type
it, the installed agents never pass it, and `--rdns` (reverse DNS) uses only
your system resolver.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository
(Security → Report a vulnerability). Please do not open a public issue.

Include what you observed and how to reproduce it. This is a single-maintainer
project; expect an acknowledgement within a week.
