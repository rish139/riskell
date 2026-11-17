#!/bin/sh
# VERSION, Sources/riskell/Version.swift and the newest released heading of CHANGELOG.md must be the same number.
cd "$(dirname "$0")/.." || exit 1
v=$(tr -d ' \n' < VERSION)
s=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' Sources/riskell/Version.swift)
c=$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | head -1)
[ "$v" = "$s" ] && [ "$v" = "$c" ] && { echo "version-check: $v"; exit 0; }
echo "version-check: VERSION is $v, Version.swift says $s, CHANGELOG.md's newest release is $c"; exit 1
