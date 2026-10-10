# InView backend (draft)

An early Rust backend based on [the team plan](../larp.md). The API and graph format
are provisional and can change alongside the iOS app. This folder is independent
of any future app or map-processing workspace.

## My part

Accept reviewed navigation graphs and select routes between named nodes. The scan
prototype also accepts portable capture bundles and derives clean model placements,
map-space meshes, and sampled depth points. iPhone capture, AR alignment, live
progress, and production rendering stay with their owners in the team plan.

## What I researched

- [Axum](https://docs.rs/axum/latest/axum/) and Tokio provide a small Rust HTTP service.
- The team plan calls for filtering route requirements before Dijkstra, preserving
  each scan's coordinates, and separating ground paths from connector trips.

## What I want to build

The first pass runs locally with in-memory storage. HTTP handlers, graph types,
storage, and route selection live in separate modules so those choices can change
without rewriting the entire service.

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/health` | Service health |
| GET | `/graphs` | List graph summaries |
| PUT | `/graphs/{graph_id}` | Validate and replace a complete graph |
| GET | `/graphs/{graph_id}` | Reload the graph |
| POST | `/graphs/{graph_id}/routes` | Select a route between node IDs |
| POST | `/scans` | Validate and retain a new capture bundle |
| GET | `/scans` | List capture summaries |
| GET | `/scans/{scan_id}` | Retrieve the original capture JSON |
| GET | `/scans/{scan_id}/scene` | Derive a scene using default options |
| POST | `/scans/{scan_id}/process` | Derive a scene with explicit options |
| GET | `/scans/{scan_id}/preview` | Open a local development preview |

### Run locally

From this folder, using current stable Rust:

```sh
cargo run
```

The default address is `127.0.0.1:3000`. `INVIEW_BIND` overrides it, for example
`INVIEW_BIND=0.0.0.0:3000 cargo run` for a phone on the same trusted development
network. There is no authentication yet; the service is for local development.
`RUST_LOG=inview_backend=debug,tower_http=debug` enables request logging.

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
- Graph requests have a 2 MiB limit. Store large scan assets elsewhere once an
  upload/storage approach is chosen. Replacing a graph affects subsequent requests;
  each active route computation uses a single graph snapshot.

## What I need from the team

- Map creation: a real scan bundle and graph, coordinate metadata, and reviewed
  connector landings/served floors. Match these draft fields together before app integration.
- Navigation: agree on route properties and where maneuvers/progress are produced.
- Data: choose persistence and scan-asset storage when the capture format is known.

## My build order

1. Local graph storage/routing and portable scan ingestion/scene processing (this scaffold).
2. Exercise a real capture and graph with the iOS app and revise both draft contracts.
3. Add persistent capture/assets, better reconstruction, and shared maneuver output as needed.
4. Add authentication, availability updates, and integrations once their scope is clear.

## Risks I see

Data disappears on restart. There is no deployment or external service integration.
Geometry validation cannot prove wall clearance, scan alignment, connector identity,
or real-world accessibility; map review must establish those properties. The scan
prototype uses supplied object labels, not automatic furniture recognition. It retains
original capture JSON in memory, including unknown fields; large binary assets are
references only. Route output
is planning geometry, not live AR guidance. The draft has no graph revision handling
for active journeys, positioning, speech, turn instructions, or rerouting sessions.

## Open questions

- What do the first real capture bundle and `graph.json` exports look like?
- Does route selection stay in Rust, move to the proposed Python pipeline, or run on device?
- Which accessibility properties can the team verify for the demo?
- What belongs in Tiger Data, and where should scan bundles live?

## Checks

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```
