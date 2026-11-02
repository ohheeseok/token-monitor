#!/bin/zsh
# Build TokenMonitor with SwiftPM and assemble an ad-hoc signed .app (no Xcode required).
# Usage: scripts/bundle.sh [--install]   (--install copies to ~/Applications)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

APP="$ROOT/build/TokenMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/TokenMonitor" "$APP/Contents/MacOS/TokenMonitor"
sed "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > "$APP/Contents/Info.plist"
# Only the app's own resources; the test target's fixture bundle sits in the same folder.
cp -R "$BIN_DIR/TokenMonitor_TokenMonitor.bundle" "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/TokenMonitor.app"
  mkdir -p "$HOME/Applications"
  pkill -x TokenMonitor 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed: $DEST"
fi
