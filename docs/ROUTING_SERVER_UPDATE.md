# Routing server update · 29 September 2026

## Current status

The source-built release `20260929-source-fix` is installed in this w8g project. The original map_routing project has also been rebuilt. Both have the same GTFS and OTP graph checksums. The earlier `20260929` bundle was only prepared and never installed; it is superseded and should not be applied.

Start w8g yourself from its project root:

```sh
./start.command
```

In the app, perform a **new search**: LOHAS Park → HKU, 29 September 2026 at 11:00, Fastest, MTR enabled. Saved routes and history entries remain old snapshots until you search again.

Expected for the reference coordinates: LOHAS Park → Tseung Kwan O → North Point → HKU, with 37 minutes of MTR travel and about 50 minutes including walking/waiting. Bus alternatives remain available. Exact totals depend on your selected locations and departure time.

## Why this happened

There were two independent problems:

1. The copied native backend still had the older feed without the non-peak Tseung Kwan O branch variant. Updating map_routing did not update w8g automatically.
2. Even the newer original feed allowed OTP to group 37-minute and 59-minute MTR journeys into one pattern because they shared the same public endpoints and route ID. At some departure times the faster journey disappeared.

The permanent correction is now in map_routing's `scripts/compile_mtr_interchanges.py`. It separates synthetic whole-MTR journeys by duration while preserving source timings and service dates. The normal source build applies this automatically; no app-specific ZIP repair is needed.

The routing API enforces the rule against combining consecutive synthetic MTR journeys. Redundant MTR transfer bans are omitted from the feed to avoid excessive pattern-pair memory usage in OTP; baseline permitted transfer records remain. This experimental feed should be used with its paired API rather than an unrestricted OTP client.

## Installed components

- Matching generated GTFS, OTP graph, build configuration and release manifest.
- Shared route checker and optimizer modules from the original project.
- Native routing adapter supporting up to six route alternatives; ordered multi-stop legs use one best result each.
- Portable MTR regression check in `route_checker/check_mtr_routes.py`.

Normal runtime is self-contained inside w8g. It does not import files from map_routing or app_prototype. Account/authentication files, API keys, database contents, Swift code, map assets and saved routes were not replaced.

Backups of replaced files: `data/routing_backups/20260929-040356-535213/`.

The exact allowlist and checksums are in `data/routing_updates/20260929-source-fix/manifest.json`. The installer rejects changed files and running servers, and rolls back failed copies.

## Check after starting

In a second terminal, from the w8g root:

```sh
.venv/bin/python -B route_checker/check_mtr_routes.py --otp-port 8092
```

This queries the running OTP with the installed routing code. It does not require a login or write any account/job/history records. The checks cover weekday/weekend/reverse LOHAS Park–HKU, three other station pairs, ranking and bus alternatives.

## Reproduce future releases

From the original map_routing project, with its server stopped:

```sh
.venv/bin/python -B run.py build --offline --start-date 2026-09-17 --days 30
.venv/bin/python -B run.py check
```

This reproduces the September example from the complete cached sources. For new dates/sources, follow map_routing's `docs/SETUP.md`; offline builds require previously downloaded dependencies and source data. Source-only tests are run with `.venv/bin/python -B scripts/check_source_tests.py`.

A future upstream rebuild does not automatically update w8g. Prepare and verify a new release using the same component allowlist as this bundle, with fresh expected-old/new checksums. Stop w8g before replacing the matched feed, graph, release metadata and compatible routing modules; then restart it. Never replace native `run.py`, `server/app.py`, authentication configuration or databases with the standalone checker's entry points.

Compare `gtfs_sha256` and `graph_sha256` in both projects' `data/generated/release-manifest.json`. Matching values confirm matching artifacts on disk; a running process must also be restarted to load them.

## Data limits

The current timetable covers **17 September–16 October 2026**. It is a cached experimental schedule, not a live train-arrival guarantee. MobilityData validation completed with zero errors; warnings are preserved in the release report. A rebuild from the same sources may produce different ZIP hashes because archive metadata and calendar row order can vary; the regression checks verify routing behavior and source timings.
