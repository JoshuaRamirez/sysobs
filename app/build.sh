#!/bin/bash
# Build SysObs, wrap it in SysObs.app, ad-hoc sign it and install it to ~/Applications. Idempotent: run it again after
# any change. `set -e` stops before the install if the build fails, so a broken build never replaces the installed app
# (DeskHub's build.sh pattern). It never launches the app on its own: nothing opens on screen unless asked.
#
#   bash build.sh              build + bundle + sign + install (not launched)
#   bash build.sh --no-launch  the same; the default, spelled out
#   bash build.sh --launch     ...and open ~/Applications/SysObs.app afterwards
#   bash build.sh --no-install build + bundle + sign only
set -euo pipefail
cd "$(dirname "$0")"

NAME=SysObs
BUNDLE_ID=com.redjay.sysobs
VERSION=0.1.0
APP_SRC="$PWD/.build/$NAME.app"
APP_DST="$HOME/Applications/$NAME.app"

launch=no
install=yes
case "${1:-}" in
  --launch) launch=yes ;;
  --no-launch|"") ;;
  --no-install) install=no ;;
  *) echo "build.sh: unknown option ${1}" >&2; exit 2 ;;
esac

swift build -c release 2>&1 | grep -Ev '^\[|^Planning|Compiling|Emitting|Write auxiliary|Linking|should be located' || true
BIN="$(swift build -c release --show-bin-path)/$NAME"
[ -x "$BIN" ] || { echo "build.sh: no binary at $BIN" >&2; exit 1; }

rm -rf "$APP_SRC"
mkdir -p "$APP_SRC/Contents/MacOS" "$APP_SRC/Contents/Resources"
cp "$BIN" "$APP_SRC/Contents/MacOS/$NAME"
# An icon from an SF Symbol, when the tools are there (optional; the cpu symbol is the menu-bar look).
if [ -x "$PWD/make-icon.sh" ]; then
    bash "$PWD/make-icon.sh" "$APP_SRC/Contents/Resources/AppIcon.icns" || true
fi
cat > "$APP_SRC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>SysObs</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_SRC/Contents/PkgInfo"
plutil -lint "$APP_SRC/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP_SRC"
echo "✓ built + signed $APP_SRC"

if [ "$install" = no ]; then exit 0; fi

mkdir -p "$HOME/Applications"
rsync -a --delete "$APP_SRC/" "$APP_DST/"
codesign --force --sign - "$APP_DST"
echo "✓ installed $APP_DST"

if [ "$launch" = yes ]; then
    open -a "$APP_DST"
    echo "✓ launched"
else
    echo "not launched (open -a $APP_DST, or build.sh --launch)"
fi
