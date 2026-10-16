# w8g — native iOS journey planner

SwiftUI and MapLibre iPhone app with a standalone Python routing backend.
The app supports place search, two-point and multi-stop journeys, saved/shareable
routes, cloud synchronisation and downloaded maps for viewing saved journeys offline.
The AI trip assistant supports Gemini chat, editable trip suggestions and confirmed route searches.

## Build the iPhone app

Open `w8g.xcodeproj` in Xcode, resolve the pinned MapLibre package, choose your
signing team and iPhone, then Run. The app targets iOS 17 or newer.
`w8g/App/AppConfig.swift` holds the development server URL. Use a hostname your
phone can reach (the local default is `http://MacBook-Pro.local:8787`).
Allow local-network access when prompted. Production requires an HTTPS backend.

## Run the backend

From this repository root, run `./setup.command` once, then `./start.command`.
Python 3.12 and Java 21 or newer are required by this setup. `.venv` belongs at
the root, not inside `server/`. The API uses port 8787 and its OTP engine uses
8092. You start and stop the server in your own terminal.

Copy `.env.example` to `.env` and configure your own services. See
[authentication configuration](docs/AUTH_CONFIGURATION.md) and the
[client API](docs/CLIENT_API.md). The backend runs independently of other local projects.

## Routing data on another machine

A source-only Git clone does **not** include the local transit feed, graph,
place index, source caches or downloaded Java tools. They are intentionally
ignored. `setup.command` installs Python dependencies; it does not create a
routing dataset. Follow [routing setup/rebuild notes](docs/ROUTING_SERVER_UPDATE.md)
and [release/sync instructions](docs/APP_ROUTING_SYNC.md) to provision those
artifacts. Keep dataset attribution and snapshot information with each release.

## Layout

- `w8g/`: native app code, organised by App, Features and Shared.
- `Assets.xcassets/`: app icon and logo referenced by Xcode.
- `server/`: HTTP endpoints, job handling, authentication and record storage.
- `route_checker/`, `scripts/`: routing logic and reproducible data tooling.
- `docs/`: current API contracts, configuration and routing-data documentation.
- `tests/`: retained backend and Swift regression checks.
- `data/`, `.venv/`, `.env`: local runtime resources, excluded from Git.

## Multi-stop planning

Explore → Multi-stop supports up to ten places, including a return to the starting point. Keep order preserves
your chosen endpoints and intermediate order. Optimise order can change **all**
stops, including the start and end, and minimises travel time using the existing
server optimiser. It is a bounded search, not a promise of global optimality.
Visits support a default stay time and individual stay-time overrides. New calculations require the server;
offline mode only displays saved routes and downloaded map areas.

## Checks

Run `./scripts/check_multi_stop.sh` on a Mac with Xcode to test the planner's
payloads, ordering, validation, GPS origin and paused-request handling without
network requests or a signed-in account. Run `.venv/bin/python -B -m unittest discover -s tests -p 'test_multi_stop_jobs.py'` for the matching backend contract checks. Build the full app in Xcode as well.

Before publishing, review `git status` and staged changes. Keep `.env`, session
stores, user data, build caches and generated datasets out of the commit.

## Direct API mode and arrivals

On the sign-in screen, **Continue without account** opens online guest mode.
Explore and AI use Google Places API (New) and Routes API directly for Hong Kong
one-to-one trips. Multi-stop planning, other transport filters, and cloud sync
require signed-in server mode. There is no automatic fallback between providers.
Google transport choices are preferences, not guaranteed exclusions.

In Profile → API keys and arrivals, enter a Google Maps Platform key with Places
API (New) and Routes API enabled. Configure billing, quotas and appropriate key
restrictions in your Google project; lookups and the connection test may be billed.
Gemini remains a direct phone-to-Google request and is subject to its regional
availability. Google and Gemini credentials are stored in device-only Keychain
items shared by guest and signed-in modes, never synchronised to the w8g database.
An existing single-account Gemini key is migrated on first use.

Google results stay in memory, are attributed to Google Maps, and offer an external
Google Maps directions link. They are not saved as offline routes or drawn on
MapLibre. Direct-mode chat/results currently reset when the app is terminated.
This keeps third-party content out of the offline route store. Server-mode chats
and saved journeys retain their existing persistence.

Next arrivals is available from transit legs, AI lookup suggestions and Settings.
It reads public MTR, KMB/LWB and Citybus APIs directly, without keys or a w8g server.
Choose the operator and boarding stop; bus direction, service variant and stop
sequence stay distinct. Empty, delayed and stale responses are displayed explicitly.
Minibus, ferry and tram arrivals are not yet connected. These estimates describe
services running now, not the saved journey's original date.

Offline saved cards open an overview. Tap its map preview to open a completed
map download with the saved route and GPS. Missing downloads show an explanation.
GPS needs location permission and a usable satellite fix; map detail is limited
to the downloaded area and zoom levels.

Run `./scripts/check_direct_services.sh` for provider payload, parsing, validation
and arrival tests with fixtures (no real keys or billable requests), and
`./scripts/check_ai_confirmation.sh` for AI mode separation. Use Xcode's developer
tools, for example `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Home Screen widgets

Profile → Widgets contains a layout editor for small, medium and large journey boards.
Compact blocks occupy one grid space, wide blocks two, and expanded blocks four.
Arrival blocks use the same MTR/KMB/Citybus decoder as the app; route blocks contain only
an explicitly selected saved journey's summary. Missing operator predictions remain blank.
WidgetKit schedules refreshes; countdown timeline entries retain the operator's original
update time and are marked outdated after two minutes. Saved route times are snapshots,
not newly calculated departures.

The `W8gWidgets` extension is embedded by the app target. Both targets require the
`group.pithon.w8g.widgets` App Group in Signing & Capabilities, registered to the signing
team. If changing the bundle identifier, update both entitlements and
`WidgetDesignStorage.group` together. Widget settings never share API keys or sessions.
Save a design in the app, add the matching w8g size through the iOS Home Screen widget
gallery, then choose the named design using Edit Widget. Layouts are stored on the device.
Run `scripts/check_widgets.sh` for grid, persistence, arrival direction and stale-data checks.

Arrival blocks can filter MTR trains by destination, such as LOHAS Park only.
With All destinations selected, each mixed-destination estimate is labeled on
both Home and Lock Screen widgets. Filters apply to MTR’s returned predictions;
no estimate is invented when the requested destination is absent.

Larger route blocks show additional journey details and an optional map preview.
The refresh control requests operator data immediately; background refresh timing
is controlled by iOS. Cached results preserve their original update timestamp.
