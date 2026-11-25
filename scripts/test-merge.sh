#!/bin/bash
# Builds and runs the two-mic merge self-test (Tests/merge) without the app.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -O Sources/NeedsYou/TwoMic.swift Tests/merge/main.swift -o "$out/test-merge"
"$out/test-merge"
