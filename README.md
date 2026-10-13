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
[client API](docs/CLIENT_API.md). The app never depends on the sibling learning
assets, prototype or map_routing folders at runtime.

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

Learning guides, old code-paste ZIPs, backups and the retired browser reference
now live in the sibling `../w8g-learning-assets/`. They are optional learning
material, not app dependencies. The move inventory is stored there.

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
stores, user data, build caches and generated datasets out of the commit. The
existing Git staging area has not been altered by the cleanup.
