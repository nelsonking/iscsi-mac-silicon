#!/bin/bash
# Build the iSCSI.app SwiftUI client using the Command Line Tools only.
#   ./build_app.sh            # build into ./build/iSCSI.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iSCSI"
BUNDLE="build/${APP_NAME}.app"
MIN_MACOS="13.0"
ARCH_TARGET="arm64-apple-macos${MIN_MACOS}"

# ---------------------------------------------------------------------------
# 0. Work around an Apple Command Line Tools packaging bug: the swift include
#    dir ships BOTH `module.modulemap` and `bridging.modulemap`, each defining
#    module `SwiftBridging`, so clang reports a redefinition and no Swift file
#    that imports Foundation/SwiftUI can compile. The two files are identical
#    apart from a copyright year; we neutralise the stale `module.modulemap`
#    (with a backup). Requires sudo once.
# ---------------------------------------------------------------------------
SWIFT_INC="$(xcrun --show-sdk-path >/dev/null 2>&1; echo /Library/Developer/CommandLineTools/usr/include/swift)"
MM="$SWIFT_INC/module.modulemap"
BM="$SWIFT_INC/bridging.modulemap"
if [ -f "$MM" ] && [ -f "$BM" ] && grep -q "SwiftBridging" "$MM" 2>/dev/null; then
  echo ">> Detected the CLT duplicate-modulemap bug; neutralising $MM (one-time)."
  echo "   A backup is kept at ${MM}.bak — undo with: sudo mv ${MM}.bak ${MM}"
  sudo sh -c "cp -n '$MM' '${MM}.bak' 2>/dev/null; : > '$MM'"
fi

rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# ---------------------------------------------------------------------------
# 1. App icon (CoreGraphics, no external assets).
# ---------------------------------------------------------------------------
echo ">> Rendering app icon…"
swift make_icon.swift build >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# 2. Compile Swift sources.
# ---------------------------------------------------------------------------
echo ">> Compiling Swift sources…"
swiftc -O -target "$ARCH_TARGET" \
    -framework SwiftUI -framework AppKit -framework Combine \
    Sources/*.swift \
    -o "$BUNDLE/Contents/MacOS/${APP_NAME}"

# ---------------------------------------------------------------------------
# 3. Bundle metadata + sign.
# ---------------------------------------------------------------------------
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
echo "APPL????" > "$BUNDLE/Contents/PkgInfo"

echo ">> Ad-hoc code signing…"
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || codesign --force --sign - "$BUNDLE"

echo ""
echo "=== Built $BUNDLE ==="
echo "Run it:  open \"$BUNDLE\""
