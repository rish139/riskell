#!/bin/sh
# Checks the workspace capsule's swipe bookkeeping (Store.swift) against back-to-back swipe sequences. No windows, no trackpad.
set -e
d=$(mktemp -d); cd "$(dirname "$0")/.."
cp Sources/riskell/Store.swift "$d/Store.swift"; cp Sources/riskell/WeatherModel.swift "$d/WeatherModel.swift"; cp Sources/riskell/UsageModel.swift "$d/UsageModel.swift"; cp scripts/store-check.swift "$d/main.swift"
# WeatherModel reads the place name from the app's config: a stub stands in for it, so the check needs only these files
cat > "$d/Stub.swift" <<'STUB'
struct AppConfig { struct Location { var name: String? }; var location: Location? { nil }; static let shared = AppConfig() }
STUB
swiftc -O "$d/Stub.swift" "$d/Store.swift" "$d/WeatherModel.swift" "$d/UsageModel.swift" "$d/main.swift" -o "$d/check" && "$d/check"
