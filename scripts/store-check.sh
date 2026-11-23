#!/bin/sh
# Checks the workspace capsule's swipe bookkeeping (Store.swift) against back-to-back swipe sequences. No windows, no trackpad.
set -e
d=$(mktemp -d); cd "$(dirname "$0")/.."
cp Sources/riskell/Store.swift "$d/Store.swift"; cp scripts/store-check.swift "$d/main.swift"
# Store.swift imports RiskellWM (the window-manager value types), so that module is compiled from its sources first: the check needs
# swiftc and nothing from SwiftPM's build folder, whose layout differs between toolchains. RiskellWM imports RiskellKit (the types a
# manager hook is handed), so the kit's sources, which SwiftPM has checked out, are compiled the same way before it.
kit=.build/checkouts/riskell-kit/Sources/RiskellKit
swiftc -O -wmo -parse-as-library -module-name RiskellKit -emit-module -emit-module-path "$d/RiskellKit.swiftmodule" -c "$kit"/*.swift -o "$d/RiskellKit.o"
swiftc -O -wmo -parse-as-library -module-name RiskellWM -I "$d" -emit-module -emit-module-path "$d/RiskellWM.swiftmodule" -c Sources/RiskellWM/*.swift -o "$d/RiskellWM.o"
swiftc -O -I "$d" "$d/Store.swift" "$d/main.swift" "$d/RiskellWM.o" "$d/RiskellKit.o" -o "$d/check" && "$d/check"
