#!/usr/bin/env bash
# Builds and signs "Needs You.app". Used by scripts/install.sh (local install)
# and by the release workflow (Developer ID build).
#
# Environment (all optional):
#   OUT=build/Needs You.app     where the bundle goes
#   VERSION=1.2.3               CFBundleShortVersionString (default: Info.plist)
#   BUILD_NUMBER=42             CFBundleVersion (default: Info.plist)
#   SIGN_IDENTITY=<sha1|name>   codesign identity, "-" for ad-hoc
#                               (default: the Needs You Developer ID certificate,
#                               the same one releases use; see AGENTS.md)
#   TIMESTAMP=1                 secure timestamp (needed for notarization)
#   FEED_URL=https://…          Sparkle appcast; without it the build has no
#                               in-app updates (local builds)
#   ED_PUBLIC_KEY=<base64>      Sparkle EdDSA public key (with FEED_URL)
#   BUNDLE_ID=…                 override the bundle id (update tests only)
#   SKIP_BUILD=1                reuse .build/release
set -euo pipefail
cd "$(dirname "$0")/.."

app=${OUT:-build/Needs You.app}
# Local and release builds sign with the same Developer ID certificate, so macOS
# keeps Accessibility, Microphone and Speech Recognition across updates and rebuilds.
needs_you_cert=F5F5EF29141AD0A613C1B7AAEB2DE13D432068A2
if [ -z "${SIGN_IDENTITY:-}" ]; then
  security find-identity -v -p codesigning | grep -q "$needs_you_cert" || {
    echo "The Needs You Developer ID certificate ($needs_you_cert) is not in your keychain." >&2
    echo "Import MACOS_CERT_P12 (with MACOS_CERT_PASSWORD) from the team's secret store, or set SIGN_IDENTITY." >&2
    exit 1
  }
fi
identity=${SIGN_IDENTITY:-$needs_you_cert}
ts=--timestamp=none
[ "${TIMESTAMP:-0}" = 1 ] && ts=--timestamp

# Apple Silicon only (WhisperKit and FluidAudio need the Neural Engine).
[ "$(uname -m)" = arm64 ] || { echo "build on an Apple Silicon Mac" >&2; exit 1; }
[ "${SKIP_BUILD:-0}" = 1 ] || swift build -c release
bin=.build/release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Frameworks"
# SwiftPM records SDK 14.0 in the binaries (LC_BUILD_VERSION), which keeps AppKit
# in its macOS 14 look. Stamp the SDK they were really built with, so the app
# gets the current system design (Liquid Glass sidebar, toolbar, menus).
sdk=$(xcrun --sdk macosx --show-sdk-version)
for b in NeedsYou:MacOS needs-you:Helpers; do
  xcrun vtool -set-build-version macos 14.0 "$sdk" -replace \
    -output "$app/Contents/${b#*:}/${b%%:*}" "$bin/${b%%:*}" 2>/dev/null
done
# Sparkle.framework (in-app updates) next to the executable's rpath.
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/NeedsYou" 2>/dev/null || true

plist="$app/Contents/Info.plist"
cp Info.plist "$plist"
pb=/usr/libexec/PlistBuddy
[ -n "${VERSION:-}" ] && $pb -c "Set :CFBundleShortVersionString $VERSION" "$plist"
[ -n "${BUILD_NUMBER:-}" ] && $pb -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"
[ -n "${BUNDLE_ID:-}" ] && $pb -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist"
if [ -n "${FEED_URL:-}" ]; then
  : "${ED_PUBLIC_KEY:?ED_PUBLIC_KEY is needed with FEED_URL}"
  $pb -c "Add :SUFeedURL string $FEED_URL" \
      -c "Add :SUPublicEDKey string $ED_PUBLIC_KEY" \
      -c "Add :SUEnableAutomaticChecks bool true" \
      -c "Add :SUScheduledCheckInterval integer 86400" \
      -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$plist"
fi

# App icon (Resources/AppIcon): compile the Icon Composer file (Liquid Glass
# layers, Assets.car + AppIcon.icns); fall back to the prebuilt .icns.
icon=Resources/AppIcon
if xcrun --find actool >/dev/null 2>&1 && [ -d "$icon/AppIcon.icon" ]; then
  xcrun actool "$icon/AppIcon.icon" --compile "$app/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "build/AppIcon-partial.plist" >/dev/null || true
fi
[ -f "$app/Contents/Resources/AppIcon.icns" ] || cp "$icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# UI sounds (HM-1348): Rosewood cues, CC0, see ACKNOWLEDGEMENTS.md
ditto Resources/Sounds "$app/Contents/Resources/Sounds"
# SwiftPM resource bundles of dependencies (FluidAudio)
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done

# Sign inside out: Sparkle's helpers, the framework, the CLI, then the app.
sign() { codesign --force --options runtime $ts --sign "$identity" "$@"; }
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$fw/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/Helpers/needs-you"
sign --entitlements NeedsYou.entitlements "$app"
codesign --verify --deep --strict "$app"
echo "bundled $app ($($pb -c 'Print :CFBundleShortVersionString' "$plist"), signed: $identity)"
