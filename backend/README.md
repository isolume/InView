# InView backend (draft)

An early Rust backend based on [the team plan](../larp.md). The API and graph format
are provisional and can change alongside the iOS app. This folder is independent
of any future app or map-processing workspace.

## My part

Accept reviewed navigation graphs, reload them, and select routes between named
nodes. Scan processing, AR alignment, live progress, and rendering stay with their
respective owners in the team plan.

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

- Map creation: a small real graph, coordinate metadata, and reviewed connector
  landings/served floors. Match these draft fields together before app integration.
- Navigation: agree on route properties and where maneuvers/progress are produced.
- Data: choose persistence and scan-asset storage when the capture format is known.

## My build order

1. Local graph upload/reload and route selection (this scaffold).
2. Exercise one real scan graph with the iOS app and revise the draft contract.
3. Add persistence, scan-bundle references, and shared maneuver output as needed.
4. Add authentication, availability updates, and integrations once their scope is clear.

## Risks I see

Data disappears on restart. There is no deployment or external service integration.
Geometry validation cannot prove wall clearance, scan alignment, connector identity,
or real-world accessibility; map review must establish those properties. Route output
is planning geometry, not live AR guidance. The draft has no graph revision handling
for active journeys, positioning, speech, turn instructions, or rerouting sessions.

## Open questions

- What does the first real `graph.json` export look like?
- Does route selection stay in Rust, move to the proposed Python pipeline, or run on device?
- Which accessibility properties can the team verify for the demo?
- What belongs in Tiger Data, and where should scan bundles live?

## Checks

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```
