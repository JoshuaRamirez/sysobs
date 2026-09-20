#!/usr/bin/env bash
#
# sysobs uninstaller — removes exactly what install.sh put there.
#
# By DEFAULT your data survives. The store is the thing that took months to
# accumulate and it is the one thing you cannot re-create; the agents and the
# symlink are re-installable in ten seconds. Deleting the store needs --purge
# and a typed confirmation.

set -euo pipefail

PREFIX="${SYSOBS_PREFIX:-$HOME/.local}"
STORE="${SYSOBS_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/sysobs}"
LABEL_PREFIX="${SYSOBS_LABEL_PREFIX:-local.sysobs}"
LOGDIR="$HOME/Library/Logs"
AGENTS="$HOME/Library/LaunchAgents"
SVCDIR="${XDG_CONFIG_HOME:-$HOME/.config}/svc/services.d"

PURGE=0
RMLOGS=0
ALL_LABELS=0
DRYRUN=0
YES=0

usage() {
  cat <<EOF
usage: ./uninstall.sh [options]

  --purge             ALSO delete the data store at
                      $STORE
                      (asks for confirmation; this is not recoverable)
  --logs              also delete $LOGDIR/sysobs*.log
  --all-labels        remove every sysobs agent found, whatever its label
                      prefix — use this to clean up after an older install
  --prefix DIR        where the executable was installed (default $PREFIX)
  --label-prefix S    launchd label prefix        (default $LABEL_PREFIX)
  --store DIR         store location              (default $STORE)
  --yes               do not prompt for --purge (for scripts)
  --dry-run           print what would happen, change nothing
  -h, --help          this

Without --purge this is fully reversible: re-run ./install.sh and the
collector picks up on the same store where it left off.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)        PURGE=1; shift ;;
    --logs)         RMLOGS=1; shift ;;
    --all-labels)   ALL_LABELS=1; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --label-prefix) LABEL_PREFIX="$2"; shift 2 ;;
    --store)        STORE="$2"; shift 2 ;;
    --yes)          YES=1; shift ;;
    --dry-run)      DRYRUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "uninstall: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
run()  { if [ "$DRYRUN" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- agents

step "Stopping and removing launchd agents"

labels=()
if [ "$ALL_LABELS" = 1 ]; then
  for p in "$AGENTS"/*sysobs*.plist; do
    [ -e "$p" ] || continue
    labels+=("$(basename "$p" .plist)")
  done
else
  labels=("$LABEL_PREFIX" "$LABEL_PREFIX-procwatch" "$LABEL_PREFIX-prune")
fi

found=0
for label in "${labels[@]:-}"; do
  [ -n "$label" ] || continue
  plist="$AGENTS/$label.plist"
  loaded=0
  launchctl print "gui/$UID/$label" >/dev/null 2>&1 && loaded=1
  if [ "$loaded" = 0 ] && [ ! -e "$plist" ]; then continue; fi
  found=1
  [ "$loaded" = 1 ] && run launchctl bootout "gui/$UID/$label" 2>/dev/null || true
  [ -e "$plist" ] && run rm -f "$plist"
  say "$label — removed"
  if [ -e "$SVCDIR/$label.json" ]; then
    run rm -f "$SVCDIR/$label.json"
    say "$label — svc descriptor removed"
  fi
done
[ "$found" = 0 ] && say "none installed"

# procwatch is KeepAlive. If bootout raced a respawn, say so rather than
# leaving a process quietly writing to a store we are about to declare removed.
if [ "$DRYRUN" = 0 ] && pgrep -f 'sysobs procwatch' >/dev/null 2>&1; then
  say "WARNING: a 'sysobs procwatch' process is still running."
  say "         pkill -f 'sysobs procwatch'"
fi

# ---------------------------------------------------------------- executable

step "Removing the executable"
TARGET="$PREFIX/bin/sysobs"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  run rm -f "$TARGET"
  say "$TARGET — removed"
else
  say "not present at $TARGET"
fi

# ---------------------------------------------------------------- logs

if [ "$RMLOGS" = 1 ]; then
  step "Removing logs"
  for f in "$LOGDIR"/sysobs*.log; do
    [ -e "$f" ] || continue
    run rm -f "$f"; say "$(basename "$f") — removed"
  done
fi

# ---------------------------------------------------------------- store

step "Data store"
if [ ! -d "$STORE" ]; then
  say "nothing at $STORE"
elif [ "$PURGE" = 0 ]; then
  say "KEPT at $STORE ($(du -sh "$STORE" 2>/dev/null | cut -f1))"
  say "Re-run ./install.sh and collection resumes on this same store."
  say "To delete it: ./uninstall.sh --purge"
else
  size="$(du -sh "$STORE" 2>/dev/null | cut -f1)"
  snaps="$( [ -f "$STORE/tables/snapshot.csv" ] && echo $(( $(wc -l < "$STORE/tables/snapshot.csv") - 1 )) || echo '?' )"
  say "About to delete $STORE"
  say "  $size, $snaps snapshots. This cannot be undone."
  if [ "$DRYRUN" = 1 ]; then
    say "would: rm -rf $STORE"
  elif [ "$YES" = 1 ]; then
    rm -rf "$STORE"; say "deleted"
  else
    printf '\n  Type the word PURGE to confirm: '
    read -r reply
    if [ "$reply" = "PURGE" ]; then rm -rf "$STORE"; say "deleted"
    else say "not confirmed — store left in place"; fi
  fi
fi

step "Uninstalled"
