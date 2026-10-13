#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/w8g-ai-confirm.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Use the production message/proposal types, with a fake Gemini transport in the checks.
python3 - "$root" "$work" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root / 'w8g/Features/AI/GeminiService.swift').read_text()
marker = '@MainActor\nstruct GeminiService'
assert marker in source
(work / 'AITypes.swift').write_text(source.split(marker)[0])
PY
xcrun swiftc -module-cache-path "$work/modules" \
    "$root/w8g/Features/AI/AIChatModel.swift" \
    "$root/w8g/Features/AI/AIConfirmedRouteService.swift" \
    "$root/w8g/Features/Routing/RoutePlannerModel.swift" \
    "$root/w8g/Features/Routing/RouteService.swift" \
    "$root/w8g/Shared/Models/Place.swift" \
    "$work/AITypes.swift" \
    "$root/tests/swift/AIConfirmationChecks.swift" -o "$work/checks"
"$work/checks"
