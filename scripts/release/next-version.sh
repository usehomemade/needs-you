#!/usr/bin/env bash
# Prints the next release version from the commits since the last v* tag:
#   "feat!:" / "BREAKING CHANGE" → major, "feat:" → minor, anything else → patch.
# First release (no tag yet): 1.0.0. Prints nothing when there is nothing new
# or every new commit says [skip release].
set -euo pipefail
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [ -z "$last" ]; then echo 1.0.0; exit 0; fi
range="$last..HEAD"
subjects=$(git log --format=%s "$range")
[ -n "$subjects" ] || exit 0
echo "$subjects" | grep -qv '\[skip release\]' || exit 0
IFS=. read -r major minor patch <<<"${last#v}"
if git log --format=%B "$range" | grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING CHANGE'; then
  echo "$((major + 1)).0.0"
elif echo "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
  echo "$major.$((minor + 1)).0"
else
  echo "$major.$minor.$((patch + 1))"
fi
