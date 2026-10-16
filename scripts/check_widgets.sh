#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/w8g-widgets.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path "$work/modules" \
 "$root/WidgetShared/WidgetModels.swift" \
 "$root/WidgetShared/WidgetStorage.swift" \
 "$root/WidgetShared/WidgetArrivalLoader.swift" \
 "$root/w8g/Features/DirectServices/ArrivalService.swift" \
 "$root/w8g/Shared/Models/MTRLineStyle.swift" \
 "$root/W8gWidgets/WidgetNetwork.swift" \
 "$root/tests/swift/WidgetChecks.swift" -o "$work/checks"
"$work/checks"
