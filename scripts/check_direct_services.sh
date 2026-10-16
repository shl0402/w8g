#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/w8g-direct.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path "$work/modules" \
 "$root/w8g/Shared/Models/Journey.swift" \
 "$root/w8g/Shared/Models/JourneyTrips.swift" \
 "$root/w8g/Shared/Models/JourneyPresentation.swift" \
 "$root/w8g/Shared/Models/MTRJourneySections.swift" \
 "$root/w8g/Shared/Models/MTRLineStyle.swift" \
 "$root/w8g/Shared/Models/Place.swift" \
 "$root/w8g/Features/Routing/RoutePlannerModel.swift" \
 "$root/w8g/Features/Routing/RouteService.swift" \
 "$root/w8g/Features/DirectServices/DirectAPI.swift" \
 "$root/w8g/Features/DirectServices/ArrivalService.swift" \
 "$root/w8g/Features/DirectServices/ArrivalSelection.swift" \
 "$root/tests/swift/DirectServiceChecks.swift" -o "$work/checks"
"$work/checks"
