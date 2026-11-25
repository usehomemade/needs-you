#!/usr/bin/env bash
# Writes a one-item Sparkle appcast for a release zip.
#
#   scripts/release/appcast.sh <zip> <version> <build> <download-url> > appcast.xml
# Environment: SPARKLE_ED_PRIVATE_KEY (base64), SPARKLE_BIN (Sparkle's bin/),
# RELEASE_NOTES_URL (optional).
set -euo pipefail
zip=$1 version=$2 build=$3 url=$4
bin=${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}
: "${SPARKLE_ED_PRIVATE_KEY:?}"
attrs=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - "$zip")
min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
notes=""
[ -n "${RELEASE_NOTES_URL:-}" ] && notes="<sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Needs You</title>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min</sparkle:minimumSystemVersion>
      $notes
      <enclosure url="$url" type="application/octet-stream" $attrs />
    </item>
  </channel>
</rss>
XML
