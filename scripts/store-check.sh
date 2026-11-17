#!/bin/sh
# Checks the workspace capsule's swipe bookkeeping (Store.swift) against back-to-back swipe sequences. No windows, no trackpad.
set -e
d=$(mktemp -d); cd "$(dirname "$0")/.."
cp Sources/riskell/Store.swift "$d/Store.swift"; cp scripts/store-check.swift "$d/main.swift"
swiftc -O "$d/Store.swift" "$d/main.swift" -o "$d/check" && "$d/check"
