#!/bin/bash
# Build Lattice.app: release binaries → bundle → sign (stable identity, so macOS keeps the
# Accessibility grant across rebuilds — an ad-hoc signature changes every build and loses it).
#
#   scripts/build-app.sh            → build/Lattice.app
#   scripts/build-app.sh --install  → also copy to ~/Applications/Lattice.app
#
# Signing identity: LATTICE_SIGN_IDENTITY, or put `LATTICE_SIGN_IDENTITY="…"` in scripts/signing.env
# (local, never committed). `security find-identity -v -p codesigning` lists yours. A stable identity
# ("Developer ID Application: …" or "Apple Development: …") keeps macOS's Accessibility grant across
# rebuilds; without one the app is signed ad-hoc ("-") and macOS asks for the grant again after every build.
#
# Version: CFBundleShortVersionString = the latest vX.Y.Z tag (or LATTICE_VERSION), CFBundleVersion = git describe.
# LATTICE_TIMESTAMP=1 adds Apple's secure timestamp (required for notarisation; scripts/release.sh sets it).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f scripts/signing.env ]] && source scripts/signing.env
IDENTITY="${LATTICE_SIGN_IDENTITY:--}"
[[ "$IDENTITY" == "-" ]] && echo "⚠️  no LATTICE_SIGN_IDENTITY — signing ad-hoc (Accessibility must be re-granted after each build)"
BUNDLE_ID="com.ijcodelabs.lattice"
SHORT_VERSION="${LATTICE_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)}"
SHORT_VERSION="${SHORT_VERSION#v}"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
OUT="${LATTICE_OUT:-build}"          # output folder (e.g. a scratch dir while your daily Lattice runs from build/)
APP="$OUT/Lattice.app"

mkdir -p "$OUT"
if pgrep -f "$(cd "$OUT" && pwd -P)/Lattice.app/Contents/MacOS/Lattice" >/dev/null; then
  echo "Lattice is running from $APP — quit it from the menu bar (▦ → Quit) before rebuilding"; exit 1
fi

swift build -c release --product lattice
swift build -c release --product lattice-ui
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/lattice" "$APP/Contents/MacOS/Lattice"          # main executable = the CLI (no args → app mode)
cp "$BIN/lattice-ui" "$APP/Contents/MacOS/lattice-ui"    # UI helper, found next to the main binary
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Lattice</string>
  <key>CFBundleDisplayName</key><string>Lattice</string>
  <key>CFBundleExecutable</key><string>Lattice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lattice — keyboard-first tiling for macOS</string>
</dict>
</plist>
PLIST

# Sign inside-out: helper first, then the app (hardened runtime; AX/event taps don't need entitlements).
HARDEN=(--options runtime); [[ "$IDENTITY" == "-" ]] && HARDEN=()
STAMP=(--timestamp=none); [[ "${LATTICE_TIMESTAMP:-}" == 1 ]] && STAMP=(--timestamp)
codesign --force "${HARDEN[@]}" "${STAMP[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/lattice-ui"
codesign --force "${HARDEN[@]}" "${STAMP[@]}" --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "built $APP $SHORT_VERSION ($VERSION) signed by: $IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  if pgrep -f "Lattice.app/Contents/MacOS/Lattice" >/dev/null; then
    echo "Lattice.app is running — quit it from the menu bar first"; exit 1
  fi
  rm -rf "$HOME/Applications/Lattice.app"
  cp -R "$APP" "$HOME/Applications/Lattice.app"
  echo "installed ~/Applications/Lattice.app"
fi
