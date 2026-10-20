#!/usr/bin/env bash
#
# sysobs installer — idempotent. Running it twice is the same as running it once.
#
# Installs three things, each of which uninstall.sh knows how to remove:
#   1. the `sysobs` executable on PATH (symlink to this checkout, or a copy)
#   2. the jobs: the sampler (`sysobs watch`) and procwatch under substrate
#      (`sub enable`) when sub is on this machine, else as launchd agents;
#      the weekly prune as a launchd agent either way
#   3. svc descriptors, if svc is on this machine (optional, skipped silently)
#
# Every job runs an absolute interpreter (Homebrew's python3 when present):
# launchd's PATH finds /usr/bin/python3, the Xcode 3.9 stub, otherwise.
#
# It does NOT create or touch the data store. sysobs makes that itself on first
# write, and uninstall leaves it alone unless you ask for --purge.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${SYSOBS_PREFIX:-$HOME/.local}"
STORE="${SYSOBS_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/sysobs}"
LABEL_PREFIX="${SYSOBS_LABEL_PREFIX:-local.sysobs}"
LOGDIR="$HOME/Library/Logs"
AGENTS="$HOME/Library/LaunchAgents"
SVCDIR="${XDG_CONFIG_HOME:-$HOME/.config}/svc/services.d"

INTERVAL=300      # seconds between snapshots
POLL=1            # procwatch pid-list poll interval
KEEPDAYS=90       # prune horizon
FULLDAYS=1        # keep EVERY snapshot this recent
THINTO=1h         # beyond that, keep one snapshot per bucket
MODE=symlink      # or `copy`
WANT_AGENTS=1
WANT_SVC=auto
WANT_SUB=auto
WANT_SELFTEST=0
DRYRUN=0
SUB="${SYSOBS_SUB:-$(command -v sub 2>/dev/null || true)}"
# superseded agents are moved here, never deleted
ASIDE="${SYSOBS_ASIDE:-${XDG_STATE_HOME:-$HOME/.local/state}/sysobs-aside}"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<EOF

usage: ./install.sh [options]

  --prefix DIR        install the executable under DIR/bin   (default $PREFIX)
  --store DIR         where snapshots live                   (default $STORE)
  --label-prefix S    launchd label prefix                    (default $LABEL_PREFIX)
  --interval N        seconds between snapshots               (default $INTERVAL)
  --poll N            procwatch poll interval in seconds      (default $POLL)
  --keep-days N       prune horizon in days                   (default $KEEPDAYS)
  --full-days N       keep every snapshot this recent         (default $FULLDAYS)
  --thin-to DUR       thin older snapshots to one per bucket  (default $THINTO)
  --copy              copy the executable instead of symlinking it
  --no-agents         install the executable only, no launchd agents
  --no-svc            skip svc descriptors even if svc is installed
  --no-substrate      launchd agents for the sampler and procwatch even if sub is installed
  --python PATH       the interpreter the jobs run          (default Homebrew python3)
  --selftest          run the selftest first and stop if it fails (off by default:
                      its procwatch fixture can miss a 0.35 s process on a pegged machine)
  --dry-run           print what would happen, change nothing
  -h, --help          this

Re-running with different options rewrites the agents in place.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)       PREFIX="$2"; shift 2 ;;
    --store)        STORE="$2"; shift 2 ;;
    --label-prefix) LABEL_PREFIX="$2"; shift 2 ;;
    --interval)     INTERVAL="$2"; shift 2 ;;
    --poll)         POLL="$2"; shift 2 ;;
    --keep-days)    KEEPDAYS="$2"; shift 2 ;;
    --full-days)    FULLDAYS="$2"; shift 2 ;;
    --thin-to)      THINTO="$2"; shift 2 ;;
    --copy)         MODE=copy; shift ;;
    --no-agents)    WANT_AGENTS=0; shift ;;
    --no-svc)       WANT_SVC=0; shift ;;
    --no-substrate) WANT_SUB=0; shift ;;
    --python)       SYSOBS_PYTHON="$2"; shift 2 ;;
    --selftest)     WANT_SELFTEST=1; shift ;;
    --dry-run)      DRYRUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "install: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
run()  { if [ "$DRYRUN" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- preflight

step "Checking this machine can run sysobs"

[ "$(uname -s)" = "Darwin" ] || {
  echo "sysobs reads macOS-only interfaces (libproc, ioreg, nettop, vm_stat)." >&2
  echo "It will not work on $(uname -s)." >&2
  exit 1
}
say "macOS $(sw_vers -productVersion) — ok"

# The jobs name their interpreter by absolute path. launchd's PATH is
# /usr/bin:/bin:..., where python3 is the Xcode 3.9 stub.
PY="${SYSOBS_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$c" ] && { PY="$c"; break; }
  done
fi
[ -n "$PY" ] || PY="$(command -v python3 || true)"
[ -n "$PY" ] && [ -x "$PY" ] || {
  echo "python3 not found. sysobs is a single python3 script; give one with --python." >&2
  exit 1
}
case "$PY" in /*) ;; *) PY="$(cd "$(dirname "$PY")" && pwd)/$(basename "$PY")" ;; esac
PYV="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
"$PY" - <<'PY' || { echo "sysobs needs python 3.9 or newer (found $PYV)." >&2; exit 1; }
import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
say "python $PYV at $PY — ok"

if [ "$WANT_SUB" = auto ]; then
  if [ -n "$SUB" ] && [ -x "$SUB" ]; then WANT_SUB=1; else WANT_SUB=0; fi
fi
[ "$WANT_SUB" = 1 ] && say "substrate at $SUB — the sampler and procwatch run under it"

[ -x "$SRC/bin/sysobs" ] || { echo "$SRC/bin/sysobs missing or not executable." >&2; exit 1; }

# The script is its own test suite. With --selftest, if the fixtures don't pass
# on this machine, stop here rather than scheduling a job that will fail.
if [ "$DRYRUN" = 0 ] && [ "$WANT_SELFTEST" = 1 ]; then
  if "$PY" "$SRC/bin/sysobs" selftest >/dev/null 2>&1; then
    say "selftest — ok"
  else
    echo "selftest FAILED. Not installing. Run: $PY $SRC/bin/sysobs selftest" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- executable

step "Installing the executable"

BIN="$PREFIX/bin"
run mkdir -p "$BIN"
TARGET="$BIN/sysobs"

if [ "$MODE" = copy ]; then
  run cp -f "$SRC/bin/sysobs" "$TARGET"
  run chmod 755 "$TARGET"
  say "copied to $TARGET"
else
  run ln -sfn "$SRC/bin/sysobs" "$TARGET"
  say "symlinked $TARGET -> $SRC/bin/sysobs"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "NOTE: $BIN is not on your PATH. Add it to your shell profile:"
     say "      export PATH=\"$BIN:\$PATH\"" ;;
esac

# ---------------------------------------------------------------- agents

if [ "$WANT_AGENTS" = 1 ]; then
  step "Installing the jobs"
  run mkdir -p "$AGENTS" "$LOGDIR"

  L_SNAP="$LABEL_PREFIX"
  L_PROC="$LABEL_PREFIX-procwatch"
  L_PRUNE="$LABEL_PREFIX-prune"
  # substrate names its agents dev.substrate.<name>; names are at most 15 chars
  N_SNAP="sysobs"
  N_PROC="sysobs-proc"
  if [ "$WANT_SUB" = 1 ]; then
    L_SNAP="dev.substrate.$N_SNAP"
    L_PROC="dev.substrate.$N_PROC"
  fi

  # Any sysobs agent under a DIFFERENT label prefix is a previous install.
  # Take it out before putting the new one in, or two collectors race for the
  # store — and the store tolerates exactly one writer.
  for old in "$AGENTS"/*sysobs*.plist; do
    [ -e "$old" ] || continue
    oldlabel="$(basename "$old" .plist)"
    case "$oldlabel" in
      "$L_SNAP"|"$L_PROC"|"$L_PRUNE") continue ;;
    esac
    # Only supersede an agent that writes the SAME store. Two collectors on
    # two different stores are not a conflict; two on one store is, because
    # dimension tables are rewritten whole and the loser's rows vanish.
    oldstore="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:SYSOBS_HOME' "$old" 2>/dev/null || echo "$STORE")"
    if [ "$oldstore" != "$STORE" ]; then
      say "leaving $oldlabel alone — it writes $oldstore, not $STORE"
      continue
    fi
    say "superseding previous install: $oldlabel (moved aside to $ASIDE)"
    run launchctl bootout "gui/$UID/$oldlabel" 2>/dev/null || true
    run mkdir -p "$ASIDE"
    run mv -f "$old" "$ASIDE/"
    if [ -e "$SVCDIR/$oldlabel.json" ]; then run mv -f "$SVCDIR/$oldlabel.json" "$ASIDE/"; fi
  done

  render() {  # render TEMPLATE LABEL > DEST
    sed -e "s|@LABEL@|$2|g" \
        -e "s|@SYSOBS@|$TARGET|g" \
        -e "s|@PY@|$PY|g" \
        -e "s|@STORE@|$STORE|g" \
        -e "s|@LOGDIR@|$LOGDIR|g" \
        -e "s|@SOURCE@|$SRC|g" \
        -e "s|@INTERVAL@|$INTERVAL|g" \
        -e "s|@POLL@|$POLL|g" \
        -e "s|@KEEPDAYS@|$KEEPDAYS|g" \
        -e "s|@FULLDAYS@|$FULLDAYS|g" \
        -e "s|@THINTO@|$THINTO|g" \
        -e "s|@STALE@|$((INTERVAL * 6))|g" \
        -e "s|@TODAY@|$(date +%F)|g" \
        "$1"
  }

  # launchctl bootout returns before the job is gone; a bootstrap straight
  # after it fails with "5: Input/output error". Wait for it to go.
  unload_wait() {  # unload_wait LABEL
    launchctl bootout "gui/$UID/$1" 2>/dev/null || true
    for _ in $(seq 1 100); do
      launchctl print "gui/$UID/$1" >/dev/null 2>&1 || return 0
      sleep 0.1
    done
  }
  load_retry() {  # load_retry PLIST
    for _ in 1 2 3 4 5; do
      launchctl bootstrap "gui/$UID" "$1" 2>/dev/null && return 0
      sleep 1
    done
    launchctl bootstrap "gui/$UID" "$1"
  }

  install_agent() {  # install_agent TEMPLATE LABEL
    local tmpl="$1" label="$2" dest="$AGENTS/$2.plist"
    if [ "$DRYRUN" = 1 ]; then say "would: write $dest and bootstrap $label"; return; fi
    render "$tmpl" "$label" > "$dest"
    plutil -lint "$dest" >/dev/null || { echo "generated $dest is not valid plist" >&2; exit 1; }
    unload_wait "$label"
    load_retry "$dest"
    say "$label — loaded"
  }

  if [ "$WANT_SUB" = 1 ]; then
    # Under substrate: named, listed by sub ps / sub-top, restarted if they
    # exit, stopped as a process group. No Nice, no Background ProcessType:
    # both raise themselves further when the machine is pegged.
    # sub enable boots the old job out and loads the new one at once; the
    # old one is unloaded first so that load does not race the unload.
    if [ "$DRYRUN" = 0 ]; then unload_wait "dev.substrate.$N_SNAP"; unload_wait "dev.substrate.$N_PROC"; fi
    run "$SUB" enable --name "$N_SNAP" --role sampler --dir "$HOME" \
        --env "SYSOBS_HOME=$STORE" \
        -- "$PY" "$TARGET" watch --interval "$INTERVAL" --files none --note substrate
    run "$SUB" enable --name "$N_PROC" --role watcher --dir "$HOME" \
        --env "SYSOBS_HOME=$STORE" \
        -- "$PY" "$TARGET" procwatch --interval "$POLL" --quiet
    # launchd starts a job with no ProcessType at base priority 20, under
    # everything at 31; nothing an unprivileged process does at run time lifts
    # that (thread QoS, taskpolicy tiers and the Darwin role were each
    # measured). ProcessType Interactive starts it at 31, as procwatch had
    # before. sub enable has no option for it yet, so it is added to the two
    # plists sub wrote, and they are reloaded.
    for n in "$N_SNAP" "$N_PROC"; do
      pl="$AGENTS/dev.substrate.$n.plist"
      if [ "$DRYRUN" = 1 ]; then say "would: set ProcessType Interactive in $pl and reload it"; continue; fi
      /usr/libexec/PlistBuddy -c "Delete :ProcessType" "$pl" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$pl"
      plutil -lint "$pl" >/dev/null
      unload_wait "dev.substrate.$n"
      load_retry "$pl"
      say "dev.substrate.$n — ProcessType Interactive"
    done
  else
    install_agent "$SRC/contrib/launchd/snapshot.plist.in"  "$L_SNAP"
    install_agent "$SRC/contrib/launchd/procwatch.plist.in" "$L_PROC"
  fi
  install_agent "$SRC/contrib/launchd/prune.plist.in"     "$L_PRUNE"

  # ------------------------------------------------------------- svc
  if [ "$WANT_SVC" != 0 ] && command -v svc >/dev/null 2>&1; then
    step "Registering with svc"
    run mkdir -p "$SVCDIR"
    for pair in "snapshot:$L_SNAP" "procwatch:$L_PROC" "prune:$L_PRUNE"; do
      t="${pair%%:*}"; l="${pair##*:}"
      if [ "$DRYRUN" = 1 ]; then say "would: write $SVCDIR/$l.json"; continue; fi
      render "$SRC/contrib/svc/$t.json.in" "$l" > "$SVCDIR/$l.json"
      say "$l — described"
    done
    say "check it with: svc health"
  fi
fi

# ---------------------------------------------------------------- done

step "Installed"
say "executable   $TARGET"
say "store        $STORE"
[ "$WANT_AGENTS" = 1 ] && say "jobs         $L_SNAP, $L_PROC, $L_PRUNE"
say "interpreter  $PY"
if [ "$WANT_SUB" = 1 ]; then
  say "logs         $LOGDIR/substrate/{$N_SNAP,$N_PROC}.log, $LOGDIR/sysobs-prune.log"
else
  say "logs         $LOGDIR/sysobs*.log"
fi
printf '\n'
say "First snapshot lands within a minute (RunAtLoad). Then:"
say "  sysobs light         the light per-tick samples"
say "  sysobs list          what has been captured"
say "  sysobs show latest   one snapshot, fully resolved"
say "  sysobs verify        referential integrity"
printf '\n'
say "To remove: ./uninstall.sh   (add --purge to delete the store too)"
