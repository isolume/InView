# InView backend (draft)

An early Rust backend based on [the team plan](../larp.md). The API and graph format
are provisional and can change alongside the iOS app. It combines capture processing,
the PostgreSQL/TimescaleDB building-frame service, and account-based map review.
See [Building maps](BUILDING_MAPS.md) for the building reference-frame contract.

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

The executable persists original scans, candidate graphs, analysis and reviewed releases.
Building reference frames, versioned alignment transforms and pose observations use
PostgreSQL/TimescaleDB when configured. HTTP handlers, graph types, storage, and route
selection live in separate modules. `AppState::default()` remains an isolated test/embedder fixture.

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/health` | Service health |
| GET/POST | `/api/buildings` | List/create building reference frames (PostgreSQL required) |
| GET | `/api/buildings/{id}` | Current or pinned map version |
| POST | `/api/buildings/{id}/alignments` | Provisionally align an uploaded scan |
| GET | `/api/buildings/{id}/observations` | Time-indexed, version-pinned camera positions |
| GET | `/api/buildings/{id}/overview` | Aligned camera paths and mesh samples |
| GET | `/scans/{id}/camera-track` | Dense movement track, with manifest/portable-frame fallback |
| GET/PUT | `/scans/{id}/analysis` | Derived worker output; 404 until processed |
| GET | `/graphs` | List graph summaries |
| PUT | `/graphs/{graph_id}` | Validate and replace a candidate graph |
| GET | `/graphs/{graph_id}` | Public reviewed graph; processing credentials can read candidates |
| POST | `/graphs/{graph_id}/routes` | Route using the same public/candidate boundary |
| GET | `/api/admin/graphs/{graph_id}` | Administrator review of the current candidate and its fingerprint |
| POST | `/api/admin/graphs/{graph_id}/publish` | Publish the exact administrator-reviewed building graph |
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

The default address is `127.0.0.1:3000`. `INVIEW_BIND` overrides it. A non-loopback
bind requires `INVIEW_API_TOKEN` containing at least 32 ASCII non-whitespace characters
and HTTPS at the reverse proxy. Processing endpoints (`/health`, scans, streams,
building frames and candidate graph writes/lists) require that bearer token whenever
configured. Account sessions do not grant processing access, and processing credentials
do not grant account or administrator access. Public catalog browsing and published
graph routing require neither token. Without a processing token, loopback development
retains the existing candidate-graph behavior used by the examples below.
`RUST_LOG=inview_backend=debug,tower_http=debug` enables request logging.
`INVIEW_SCAN_DIR` selects durable scan storage (default `data/scans`), including
`analysis/`, candidate `graphs/`, and separate `published-graphs/` snapshots and history.
`INVIEW_STREAM_DIR` selects durable stream storage (default `data/streams` relative
to this working directory). Keep one backend process per set of storage directories. See
[SCANS.md](SCANS.md#continuous-capture-prototype) for the wire contract, reconstruction
method and bounds. Set `INVIEW_DATABASE_URL` for building-frame persistence;
`INVIEW_REQUIRE_TIMESCALE=1` requires that database and verifies TimescaleDB at startup.

For local furniture recognition, install the separate inference runtime once:

```sh
bash recognition/setup.sh
cargo run --release
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
  Kinds are `elevator`, `ramp`, `stairs`, and `escalator`. One edge represents a
  complete crossing between its endpoints, with a nonnegative `estimated_seconds`.
  Elevator estimates include waiting/boarding once; add direct ride edges for
  supported floor pairs rather than chaining a ride through floors.
  Transitions return source/destination maps and floors and no ground polyline.
  Use a `ramp` transition when its landings belong to separate map or floor frames;
  do not connect those local coordinates with a fabricated path. A measured ramp
  wholly within one frame can remain a 3D surface edge.
- `step_free` is `true`, `false`, or `null`/omitted for unknown. `availability` is
  `available`, `closed`, or `unknown` (the default). Only available edges are used.
  Step-free requests require `true` and exclude stairs and escalators.
- Optional `minimum_clear_width_m` and `maximum_slope` requirements need known,
  suitable edge measurements. Slope is absolute rise/run, not degrees or percent.
  These checks enforce submitted properties; they do not certify accessibility.
- Both modes minimize the full trip's estimated seconds, including approach and
  exit paths. A fastest request uses `requires_step_free: false` with width/slope
  limits omitted or null; it can choose stairs or an elevator. A step-free request
  uses `requires_step_free: true` and the selected width/slope limits; a suitable
  ramp and elevator compete on total time. Unknown required measurements exclude
  a connection. Each request is independent, so switching modes must send the
  complete current requirements rather than carry limits from the previous mode.
- Responses retain ordered node IDs, separate surface/transition segments, total
  estimated seconds, and the requested requirements. No eligible path returns
  HTTP 422 with `error.code: "no_verified_route"`; requirements are never relaxed.
- Invalid JSON and graph/request validation return structured errors. Unknown
  fields are rejected to catch misspelled requirements. The graph-level `metadata`
  object holds experimental scan references and other data outside this small core.
- Graph requests have a 2 MiB limit. Store large scan assets elsewhere once an
  upload/storage approach is chosen. Replacing a graph affects subsequent requests;
  each active route computation uses a single graph snapshot.
- Candidate graph writes are persisted atomically before acknowledgment. Worker output
  remains a candidate: it cannot change public navigation by calling `PUT /graphs/{id}`.
- An administrator reviews `GET /api/admin/graphs/{id}`, then publishes with
  `{expected_fingerprint,geometry_reviewed:true,routes_reviewed:true,floor_links_reviewed:true}`.
  The graph must declare `metadata.venue_id` equal to its graph ID. A changed candidate
  invalidates the fingerprint (409). Publication retains a separate immutable receipt
  and advances the public snapshot. Later worker output cannot overwrite that release.
- The app's explicit **Find places** action uploads a fresh immutable package for the
  saved capture and polls its analysis. Run the separate Python worker in watch mode
  (`python -m inview_worker watch --interval 15` with the backend URL and processing token);
  Rust scene generation alone does not run the semantic pipeline. See
  [worker/README.md](worker/README.md) for setup. Suggestions retain source evidence and
  enter the draft for review; they do not replace the local map geometry.

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

The local stores support one backend process and require backups. No deployment is
performed by these changes. Database integration tests require an explicit test database.
Geometry validation cannot prove wall clearance, scan alignment, connector identity,
or real-world accessibility; map review must establish those properties. The scan
`/scans` prototype uses supplied object labels. Continuous `/streams` scans can use
the separate local furniture recognizer; uncertain results retain measured shapes.
The `/scans` store retains original capture JSON, including unknown fields, and package
sidecars in immutable local storage. Route output
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
# Optional: explicitly configured isolated PostgreSQL/TimescaleDB integration.
cargo test --test buildings -- --ignored
```

## Accounts and reviewed maps

The user-facing foundation is separate from the original reconstruction API. It
currently accepts contributions only for `student-center-east`, Floors 1–3.
Ordinary users can register, sign in, upload a saved `VenueMap`, and see their own
submissions. Only explicitly configured administrators can review and publish maps.
An uploaded or processed scan never becomes a public map automatically.

`INVIEW_PRODUCT_DIR` selects durable account/submission storage (default
`data/product`). One process holds an exclusive lock for this directory. Changes
are acknowledged after a private atomic snapshot and file/directory sync. Restart
retains accounts, sessions, source submissions, edited drafts, review history,
and published versions. This bounded file store supports one local service; it
does not replace a production database or backup system.

To create a dedicated administrator, set **both** `INVIEW_ADMIN_EMAIL` and
`INVIEW_ADMIN_PASSWORD` before launch. There is no default administrator or password.
The password must contain at least 12 characters. Bootstrap creates that account
once, does not reset an existing administrator password, and refuses to elevate
an existing contributor account. Remove bootstrap credentials from the launch
environment after initial creation. The review workspace is at `/admin`; browser
sign-in requires HTTPS or loopback, keeps its bearer token in memory, and sends no
token in a URL. Serve the service behind HTTPS before using real accounts across
a network. Configure separate processing credentials as described above.

| Method | Endpoint | Access |
|---|---|---|
| POST | `/api/accounts/register` | `{email,password,name?}` → `{token,expires_at,account}` |
| POST | `/api/accounts/login` | `{email,password}` → same response |
| GET | `/api/accounts/me` | Bearer → `{id,email,name,role}` |
| POST | `/api/accounts/logout` | Bearer → 204; revokes that session |
| GET / POST | `/api/submissions` | Bearer; own summaries / new submission |
| GET | `/api/submissions/{id}` | Owner or admin; source and current draft |
| POST | `/api/submissions/{id}/resubmit` | Owner; revised source after changes requested |
| GET | `/api/admin/submissions` | Admin review queue |
| PATCH | `/api/admin/submissions/{id}` | Admin; revision-checked draft or review decision |
| POST | `/api/admin/submissions/{id}/publish` | Admin; approves and publishes current revision |
| GET | `/api/venues/student-center-east/maps` | Public; latest published version per floor |
| GET | `/api/venues/student-center-east/maps/{floor}/versions/{version}` | Public; immutable version |

Passwords use salted Argon2id hashes. Random bearer sessions expire after 14 days;
only their SHA-256 digests are stored. Logout revokes the selected session.
Registration cannot set a role. Authentication work has two concurrent slots and
bounded process-local attempt limits (10 attempts per normalized email per 15
minutes, 10 registrations per 15 minutes). There is no email verification,
password reset, account deletion, or production abuse gateway in this first pass.

Create a submission with:

```json
{
  "client_submission_id": "868d07e2-2e7a-471f-b9dd-8b7df679b590",
  "venue_id": "student-center-east",
  "floor": 2,
  "map": {
    "createdAt": "2026-10-10T12:00:00Z",
    "floorY": 0,
    "footprints": [{ "kind": "floor", "center": [0, 0], "size": [8, 6], "yaw": 0 }],
    "points": []
  },
  "title": "Floor 2 scan",
  "notes": "Optional contributor note",
  "authorized_space": true
}
```

The geometry above is an illustrative example, not a building map. Submission
requires nonempty, validated geometry. Dates must be ISO 8601 without fractional seconds,
matching the native encoder. Vectors use arrays; the service validates supported
feature/furniture kinds, UUID identifiers, positive finite dimensions, nondegenerate
outlines, and the native display limits. Floors support at most 10,000 footprints,
1,000 destinations, 128 vertices per outline, 500-meter dimensions/overall span,
and the native position bounds. Geometry validation does not establish physical
clearance, permitted access, or accessibility.

Exact retries of `client_submission_id` are scoped to the account and return the
accepted receipt with HTTP 200; the initial upload returns 201. Different content
under that identifier returns 409. The source payload stays unchanged. Summaries
contain `id`, `owner_id`, `venue_id`, `floor`, `title`, `notes`, `status`, `revision`,
`created_at`, `updated_at`, `review_note`, and `published_version`. Timestamps are
Unix seconds. Status is `submitted`, `in_review`, `changes_requested`, or `published`.

Admin edits accept `{expected_revision,map?,review_note?,status?}`. Status edits are
limited to `in_review` or `changes_requested`; a change request needs a note. Each
edit increments the revision and invalidates an older approval. A contributor
resubmits with `{client_submission_id,expected_revision,map,notes?,authorized_space:true}`;
the service retains another immutable source, resets review, and increments the
revision. Identical resubmission retries still succeed after later review.

Publication requires `{expected_revision,geometry_reviewed:true,routes_reviewed:true,
floor_links_reviewed:true}`. It stores the exact reviewed draft as an immutable
version and updates the floor's latest public release in one durable transaction.
The public DTO is `{venue_id,name,maps:[{id,submission_id,venue_id,floor,version,
map_revision,source_revision,published_at,origin:"admin_reviewed",map,ar_ready:false}]}`.
Missing floors are omitted. Subsequent draft edits do not change existing releases.
No raw originals, account details, or review notes are served through public routes.

This upload contains map geometry and labels, not raw camera/depth files or an
ARWorldMap. All published maps report `ar_ready:false`. The service does not invent
alignment assets. The web workspace edits destination labels, types, staff
assistance and pin positions, plus review notes. Broader structural geometry and
route edits are supported by the API but need a future editor.
Source evidence is the contributor's original map and notes, not a captured photo.

Account bodies are limited to 16 KiB, submission/edit bodies to 2 MiB, and the
complete store to 128 MiB. Each user can retain up to 100 submissions, each
submission up to 20 source revisions and 200 review edits. Oversized input fails
explicitly; accepted maps are not truncated. Keep source files on the phone until
the receipt is confirmed. There is no deployment, automatic publication, or
remote administrator creation in this change.
