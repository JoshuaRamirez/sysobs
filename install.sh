#!/usr/bin/env bash
#
# sysobs installer — idempotent. Running it twice is the same as running it once.
#
# Installs three things, each of which uninstall.sh knows how to remove:
#   1. the `sysobs` executable on PATH (symlink to this checkout, or a copy)
#   2. three launchd agents: snapshot, procwatch, prune
#   3. svc descriptors, if svc is on this machine (optional, skipped silently)
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
POLL=0.1          # procwatch pid-list poll interval
KEEPDAYS=90       # prune horizon
FULLDAYS=1        # keep EVERY snapshot this recent
THINTO=1h         # beyond that, keep one snapshot per bucket
MODE=symlink      # or `copy`
WANT_AGENTS=1
WANT_SVC=auto
DRYRUN=0

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

command -v python3 >/dev/null || {
  echo "python3 not found on PATH. sysobs is a single python3 script." >&2
  exit 1
}
PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
python3 - <<'PY' || { echo "sysobs needs python 3.9 or newer (found $PYV)." >&2; exit 1; }
import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
say "python3 $PYV — ok"

[ -x "$SRC/bin/sysobs" ] || { echo "$SRC/bin/sysobs missing or not executable." >&2; exit 1; }

# The script is its own test suite. If the fixtures don't pass on this machine,
# stop here rather than scheduling a job that will fail every five minutes.
if [ "$DRYRUN" = 0 ]; then
  if "$SRC/bin/sysobs" selftest >/dev/null 2>&1; then
    say "selftest — ok"
  else
    echo "selftest FAILED. Not installing. Run: $SRC/bin/sysobs selftest" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- executable

step "Installing the executable"

BIN="$PREFIX/bin"
run mkdir -p "$BIN"
TARGET="$BIN/sysobs"

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then run rm -f "$TARGET"; fi
if [ "$MODE" = copy ]; then
  run cp "$SRC/bin/sysobs" "$TARGET"
  run chmod 755 "$TARGET"
  say "copied to $TARGET"
else
  run ln -s "$SRC/bin/sysobs" "$TARGET"
  say "symlinked $TARGET -> $SRC/bin/sysobs"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "NOTE: $BIN is not on your PATH. Add it to your shell profile:"
     say "      export PATH=\"$BIN:\$PATH\"" ;;
esac

# ---------------------------------------------------------------- agents

if [ "$WANT_AGENTS" = 1 ]; then
  step "Installing launchd agents"
  run mkdir -p "$AGENTS" "$LOGDIR"

  L_SNAP="$LABEL_PREFIX"
  L_PROC="$LABEL_PREFIX-procwatch"
  L_PRUNE="$LABEL_PREFIX-prune"

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
    say "superseding previous install: $oldlabel"
    run launchctl bootout "gui/$UID/$oldlabel" 2>/dev/null || true
    run rm -f "$old"
    run rm -f "$SVCDIR/$oldlabel.json"
  done

  render() {  # render TEMPLATE LABEL > DEST
    sed -e "s|@LABEL@|$2|g" \
        -e "s|@SYSOBS@|$TARGET|g" \
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

  install_agent() {  # install_agent TEMPLATE LABEL
    local tmpl="$1" label="$2" dest="$AGENTS/$2.plist"
    if [ "$DRYRUN" = 1 ]; then say "would: write $dest and bootstrap $label"; return; fi
    render "$tmpl" "$label" > "$dest"
    plutil -lint "$dest" >/dev/null || { echo "generated $dest is not valid plist" >&2; exit 1; }
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$dest"
    say "$label — loaded"
  }

  install_agent "$SRC/contrib/launchd/snapshot.plist.in"  "$L_SNAP"
  install_agent "$SRC/contrib/launchd/procwatch.plist.in" "$L_PROC"
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
[ "$WANT_AGENTS" = 1 ] && say "agents       $LABEL_PREFIX{,-procwatch,-prune}"
say "logs         $LOGDIR/sysobs*.log"
printf '\n'
say "First snapshot lands within a minute (RunAtLoad). Then:"
say "  sysobs list          what has been captured"
say "  sysobs show latest   one snapshot, fully resolved"
say "  sysobs verify        referential integrity"
printf '\n'
say "To remove: ./uninstall.sh   (add --purge to delete the store too)"
