# InView backend

Rust service for scan ingestion, measured scene reconstruction, reviewed graph
routing, and persistent building reference frames. The iPhone app owns AR
capture and navigation. The Python [worker](worker/README.md) derives floor maps,
text, signage, places, hazards, and navigation graphs from saved scans.

Set `INVIEW_SCAN_DIR` to persist immutable source captures and replaceable
analyses/graphs. Continuous streams use `INVIEW_STREAM_DIR` (default
`data/streams`). Building reference frames and alignment observations use
PostgreSQL, with TimescaleDB when available. See [Building maps](BUILDING_MAPS.md)
and the authenticated `start-server.sh` launcher for database configuration.

## Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/health` | Service health |
| GET/POST | `/api/buildings` | List/create persistent building reference frames (PostgreSQL required) |
| GET | `/api/buildings/{id}` | Get current or pinned map version |
| POST | `/api/buildings/{id}/alignments` | Provisionally align an already-uploaded scan |
| GET | `/api/buildings/{id}/observations` | Time-indexed, version-pinned camera positions |
| GET | `/api/buildings/{id}/overview` | Top-down preview of aligned camera paths and mesh samples |
| GET | `/scans/{id}/camera-track` | Full camera path (dense `camera-track.json` first, then package manifest, then portable frames; `source` says which) |
| GET/PUT | `/scans/{id}/analysis` | Derived OpenCV worker output (`places`, `doors`, `hazards`, `signs`, `nav_graph`, `routes`, ...); GET returns 404 `analysis_not_found` until the worker has run. See [worker/PIPELINE.md](worker/PIPELINE.md) |
| GET | `/graphs` | List graph summaries |
| PUT | `/graphs/{graph_id}` | Validate and replace a complete graph (persisted when `INVIEW_SCAN_DIR` is set; 503 `graph_storage_error` if the write fails) |
| GET | `/graphs/{graph_id}` | Reload the graph |
| POST | `/graphs/{graph_id}/routes` | Select a route between node IDs |
| POST | `/scans` | Validate and retain a new capture bundle |
| GET | `/scans` | List capture summaries |
| GET | `/scans/{scan_id}` | Retrieve the original capture JSON |
| GET | `/scans/{scan_id}/scene` | Derive a scene using default options |
| POST | `/scans/{scan_id}/process` | Derive a scene with explicit options |
| GET | `/scans/{scan_id}/preview` | Open a local development preview |
| POST | `/streams` | Create or resume a durable continuous capture |
| GET | `/streams/{id}` | Read the acknowledged upload prefix |
| PUT | `/streams/{id}/chunks/{sequence}` | Durably append one calibrated RGB/depth observation |
| POST | `/streams/{id}/finish` | Seal exactly the complete acknowledged stream |
| GET | `/streams/{id}/result` | Build compact measured geometry and its matching scene |
| GET | `/streams/{id}/scene` | Build the continuous stream's scene |

### Run locally

From this folder, using current stable Rust:

```sh
cargo run --release
```

The default address is `127.0.0.1:3000`. `INVIEW_BIND` overrides it, for example
`INVIEW_BIND=0.0.0.0:3000` behind an HTTPS reverse proxy. Non-loopback binds
require `INVIEW_API_TOKEN` (at least 32 ASCII non-whitespace characters). When a
token is configured, all data endpoints and `/health` require `Authorization:
Bearer <token>`. The studio shell is public; it prompts for the token before
fetching capture data. The iPhone rejects tokens sent to a remote plain HTTP URL.
`RUST_LOG=inview_backend=debug,tower_http=debug` enables request logging.
`INVIEW_STREAM_DIR` selects durable stream storage (default `data/streams` relative
to this working directory). Keep one backend process per directory. See
[SCANS.md](SCANS.md#continuous-capture-prototype) for the wire contract, reconstruction
method and bounds. Scans and graphs persist when `INVIEW_SCAN_DIR` is set.

For local furniture recognition, install the separate inference runtime once:

```sh
bash recognition/setup.sh
cargo run --release --locked
```

Setup downloads public dependencies and pretrained weights into an isolated,
ignored directory. The backend discovers that runtime automatically and keeps one
local model worker loaded while samples arrive. Camera images never leave this
server for recognition. `INVIEW_RECOGNITION=off` runs geometry without recognition;
`INVIEW_RECOGNITION_DEVICE` selects an inference device (default `cpu`). See
[SCANS.md](SCANS.md#server-furniture-recognition) for behavior and limitations.

In another terminal, also from this folder:

```sh
curl http://127.0.0.1:3000/health
curl -X PUT http://127.0.0.1:3000/graphs/demo-building \
  -H 'Content-Type: application/json' --data-binary @examples/graph.json
curl http://127.0.0.1:3000/graphs/demo-building
curl -X POST http://127.0.0.1:3000/graphs/demo-building/routes \
  -H 'Content-Type: application/json' --data-binary @examples/route.json
```

The synthetic example takes Elevator A to Room 204 in an estimated 34 seconds.
Its shorter stair connection is excluded by the example's step-free requirement.
It contains no real building or verified accessibility measurements.

### Try the scan prototype

```sh
curl -X POST http://127.0.0.1:3000/scans \
  -H 'Content-Type: application/json' --data-binary @examples/demo-living-room.json
curl http://127.0.0.1:3000/scans/demo-room/scene
```

Open [the local navigation preview](http://127.0.0.1:3000/scans/demo-room/preview)
to see the synthetic room as navigation scenery, with a position marker, meeting-room destination,
and a demo route computed by the iOS route planner. Furniture has no labels or
selection controls. Synthetic route metadata is ignored for real scans.
This dependency-free canvas viewer is a development aid; the iPhone app owns
the native map and AR navigation views.

The iOS app now uploads its RoomPlan capture and opens the returned scene in a
native navigation map. Version 3 processing emits shaped furniture meshes with
normals and materials; the existing cuboid parts remain a fallback. See the root
README for local iPhone networking and the offline in-app demo.

[Scan format and processing notes](SCANS.md) describe the portable capture draft,
coordinate conventions, supported processing, and the remaining iPhone adapter.

### Draft graph and routing conventions

- `schema_version: 1` labels this experiment, not a promised stable contract.
- A graph can span multiple maps and floors. Node and surface coordinates are in
  meters with ARKit's y-up axes. Preserve scan origins and rotations; identifiers
  alone do not align two scans. Store capture/export metadata in `metadata` for now.
- Connections are **directed**. Add a separate reverse edge and reversed surface
  points where travel is valid in both directions. The example only supports the
  entrance-to-room trip.
- Surface edges contain reviewed 3D `path_points` within one map and floor. Length
  comes from that polyline; estimated time is length divided by the requested
  `movement_speed_mps` (temporary default: 1). Endpoints must match within 5 cm.
- Transition edges name a connector and connect explicit boarding/exit nodes.
  One edge represents one complete ride to a served floor, with a nonnegative
  `estimated_seconds` that includes waiting/boarding once. Add direct ride edges
  for supported floor pairs rather than chaining an elevator ride through floors.
  Transitions return source/destination maps and floors and no ground polyline.
- `step_free` is `true`, `false`, or `null`/omitted for unknown. `availability` is
  `available`, `closed`, or `unknown` (the default). Only available edges are used.
  Step-free requests require `true` and exclude stairs and escalators.
- Optional `minimum_clear_width_m` and `maximum_slope` requirements need known,
  suitable edge measurements. Slope is absolute rise/run, not degrees or percent.
  These checks enforce submitted properties; they do not certify accessibility.
- Responses retain ordered node IDs, separate surface/transition segments, total
  estimated seconds, and the requested requirements. No eligible path returns
  HTTP 422 with `error.code: "no_verified_route"`; requirements are never relaxed.
- Invalid JSON and graph/request validation return structured errors. Unknown
  fields are rejected to catch misspelled requirements. The graph-level `metadata`
  object holds experimental scan references and other data outside this small core.
- Graph requests have a 2 MiB limit. Use scan packages for large capture assets. Replacing a graph affects subsequent requests;
  each active route computation uses a single graph snapshot.
- Graph persistence: with `INVIEW_SCAN_DIR`, each accepted graph is written atomically
  (temp file, fsync, rename) to `INVIEW_SCAN_DIR/graphs/<sha256(graph id)>.json` before
  the PUT is acknowledged, and all graphs are reloaded at startup. Unreadable, invalid
  or misnamed graph files are logged and skipped rather than blocking startup.
- The Python worker's `publishers/graph.py` PUTs the analysis `nav_graph` product
  (`id = "<scan_id>-nav"`) here after storing the analysis. A scan with a navigation graph is routable via `POST /graphs/<scan_id>-nav/routes`.
  Scans without a `nav_graph` are skipped; 422
  validation errors are logged by the worker.
- The iOS app (`BackendClient.analysis(scanID:)`) polls `GET /scans/{id}/analysis` in the
  background after processing and merges `places`
  into the draft map's destination points with stable IDs, never replacing points the
  volunteer added.

## Operational limits

Use one backend process per storage directory. Geometry endpoints share a
four-request admission limit; excess requests return 503 `processing_busy`.
Continuous reconstruction permits two builders at once. SIGINT and SIGTERM drain
active HTTP requests. Accepted durable writes finish even if the client disconnects.

Back up the scan directory together with the database. Without `INVIEW_SCAN_DIR`,
source scans and graphs disappear on restart. The [Vultr configuration](infra/README.md)
provides HTTPS and container-persistent local files; it does not provision a database.

Geometry validation checks data consistency, not real-world clearance or
accessibility. Alignment and connector properties still require review. Routing
returns planning geometry; live positioning, speech, and rerouting run on the phone.

## Checks

```sh
cargo fmt --check
cargo test --locked
cargo clippy --all-targets -- -D warnings
```
