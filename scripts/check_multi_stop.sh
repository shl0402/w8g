#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/w8g-multi.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path "$work/modules" \
    "$root/w8g/Features/Routing/RoutePlannerModel.swift" \
    "$root/w8g/Features/Routing/RouteService.swift" \
    "$root/w8g/Shared/Models/Place.swift" \
    "$root/tests/swift/MultiStopChecks.swift" -o "$work/checks"
"$work/checks"
