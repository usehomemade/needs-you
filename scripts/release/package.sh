#!/usr/bin/env bash
# Notarizes and packages a signed "Needs You.app":
#   dist/NeedsYou-<version>.zip  (Sparkle update + Homebrew cask)
#   dist/NeedsYou-<version>.dmg  (download page)
#
#   scripts/release/package.sh <app> <version>
# Environment: NOTARIZE=1 with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (.p8
# file) to notarize and staple; SIGN_IDENTITY signs the DMG.
set -euo pipefail
app=$1 version=$2
out=${DIST:-dist}
mkdir -p "$out"
zip="$out/NeedsYou-$version.zip" dmg="$out/NeedsYou-$version.dmg"
rm -f "$zip" "$dmg"

notarize() {
  xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 30m --output-format json > "$out/notary.json"
  status=$(/usr/bin/plutil -extract status raw "$out/notary.json" 2>/dev/null || python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$out/notary.json")
  echo "notarization of $(basename "$1"): $status"
  if [ "$status" != Accepted ]; then
    id=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$out/notary.json")
    xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
    exit 1
  fi
}

if [ "${NOTARIZE:-0}" = 1 ]; then
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  notarize "$out/notarize.zip"
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Needs You" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "$stage"
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != - ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
if [ "${NOTARIZE:-0}" = 1 ]; then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
fi
ls -l "$zip" "$dmg"
