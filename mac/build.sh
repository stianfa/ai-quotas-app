#!/bin/bash
# Builds AIQuotas.app — a self-contained menu bar app, no Xcode project needed.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AIQuotas"
BUNDLE_ID="local.aiquotas.app"
SRC="AIQuotas/Sources/AIQuotas"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
DEST="${1:-}"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling (arm64, macOS 14)…"
swiftc \
  -O -whole-module-optimization \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Security \
  -parse-as-library \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$SRC"/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>AI Quotas</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc is fine here. Claude credentials are read-only through /usr/bin/security,
# the Apple-signed binary the Claude Code keychain item already trusts (see
# Credentials.keychainRead). That avoids repeat prompts as the app's ad-hoc code
# identity changes between builds.
echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null

# A failed signature must not pass silently — the old one stays on disk and the
# app would keep re-prompting for keychain access with no visible cause.
codesign --verify --strict "$APP" || { echo "✗ Signature verification failed"; exit 1; }

echo "✓ Built $APP"

if [ -n "$DEST" ]; then
  echo "→ Installing to ${DEST}…"
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  echo "✓ Installed $DEST/$APP_NAME.app"
fi
