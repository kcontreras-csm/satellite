#!/bin/bash
# Builds Satellite and wraps it into dist/Satellite.app (ad-hoc signed).
#
#   scripts/bundle.sh [release|debug]
#
# The version is stamped into the BUILT bundle only. CI passes VERSION from the release tag; local builds
# use the newest git tag (or 0.1.0 before the first release). Info.plist keeps a placeholder.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Satellite"

APP="dist/Satellite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Satellite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Version: VERSION env (CI) > newest tag > 0.1.0. Always plain major.minor.patch, which is what the updater compares.
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || VERSION="0.1.0"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

# Build info shown in Settings > General.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "no commit")"
if [[ "$COMMIT" != "no commit" ]] && ! git diff --quiet HEAD 2>/dev/null; then COMMIT="$COMMIT (modified)"; fi
plutil -insert SatelliteBuild -string "$COMMIT" "$APP/Contents/Info.plist"
echo "Stamped version $VERSION ($COMMIT)"

# App icon: Resources/Icon.png -> AppIcon.icns.
if [[ -f Resources/Icon.png ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" Resources/Icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) Resources/Icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --identifier com.kcontreras.satellite "$APP"

# Nudge Finder/LaunchServices so the icon shows up (it caches aggressively when a bundle is recreated).
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
