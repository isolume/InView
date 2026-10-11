# InView backend

Rust service for scan ingestion, measured scene reconstruction, reviewed graph
routing, persistent building reference frames, and account-based map review.
The iPhone app owns AR capture and navigation. The Python [worker](worker/README.md)
derives floor maps, text, signage, places, hazards, and candidate navigation graphs
from saved scans. The API and graph format remain provisional; see
[the team plan](../larp.md) and [Building maps](BUILDING_MAPS.md).

The executable persists immutable source captures and replaceable analyses/graphs
in `INVIEW_SCAN_DIR` (default `data/scans`). Continuous streams use
`INVIEW_STREAM_DIR` (default `data/streams`). Building reference frames and alignment observations use
PostgreSQL, with TimescaleDB when available. See [Building maps](BUILDING_MAPS.md)
and the authenticated `start-server.sh` launcher for database configuration.

HTTP handlers, graph types, storage and route selection live in separate modules.
`AppState::default()` remains an isolated test/embedder fixture.

## Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/health` | Service health |
| GET/POST | `/api/buildings` | List/create building reference frames (PostgreSQL required) |
| GET | `/api/buildings/{id}` | Current or pinned map version |
| POST | `/api/buildings/{id}/alignments` | Provisionally align an uploaded scan |
| GET | `/api/buildings/{id}/observations` | Time-indexed, version-pinned camera positions |
| GET | `/api/buildings/{id}/overview` | Aligned camera paths and mesh samples |
| POST | `/api/buildings/{id}/routes` | Distinct multi-floor routes across the building's aligned scans |
| GET | `/api/buildings/{id}/levels` | Floors and connectors for a level picker |
| POST | `/api/buildings/{id}/nearby` | Places, signs and connectors around a point, searchable by name |
| GET/POST | `/api/buildings/{id}/connectors` | Manually registered elevators, stairs, escalators and ramps |
| POST | `/scans/{id}/routes` | The same routes within one processed scan (no database) |
| GET | `/scans/{id}/levels` | Floors and connectors of one processed scan |
| POST | `/scans/{id}/nearby` | The same nearby search within one processed scan |
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
cargo run --release --locked
```

The default address is `127.0.0.1:3000`. `INVIEW_BIND` overrides it, for example
`INVIEW_BIND=0.0.0.0:3000` behind an HTTPS reverse proxy. A non-loopback bind
requires `INVIEW_API_TOKEN` containing at least 32 ASCII non-whitespace characters.
Processing endpoints (`/health`, scans, streams, building frames and candidate graph
writes/lists) require `Authorization: Bearer <token>` whenever configured. Account
sessions do not grant processing access, and processing credentials do not grant
account or administrator access. Public catalog browsing and published graph
routing require neither token. The studio shell is public and prompts for the
processing token before fetching capture data. The iPhone rejects tokens sent to
a remote plain HTTP URL. Without a processing token, loopback development retains
the candidate-graph behavior used by the examples below.
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

The iOS app builds its RoomPlan map and scene on-device. During review,
**Find places** can upload a separate evidence package for worker suggestions;
the returned geometry does not replace the local map. The server retains its
scene-processing API: version 3 emits shaped furniture meshes with normals and
materials, with cuboid parts as a fallback. See the root README for local iPhone
networking and the offline in-app demo.

[Scan format and processing notes](SCANS.md) describe the portable capture draft,
coordinate conventions, supported processing, and the current iPhone adapter.

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
- Graph requests have a 2 MiB limit. Use scan packages for large capture assets. Replacing a graph affects subsequent requests;
  each active route computation uses a single graph snapshot.
- Candidate graph writes are persisted atomically before acknowledgment under
  `INVIEW_SCAN_DIR/graphs/<sha256(graph id)>.json` (temp file, fsync, rename), and
  accepted graphs are reloaded at startup. Unreadable, invalid or misnamed graph
  files are logged and skipped rather than blocking startup. Worker output remains
  a candidate: `PUT /graphs/{id}` cannot change public navigation.
- The Python worker's `publishers/graph.py` writes the analysis `nav_graph` product
  (`id = "<scan_id>-nav"`) after storing the analysis. Processing credentials can
  route against that candidate via `POST /graphs/<scan_id>-nav/routes`; loopback
  development without a processing token also supports candidate routing. Scans
  without a `nav_graph` are skipped; 422 validation errors are logged by the worker.
- An administrator reviews `GET /api/admin/graphs/{id}`, then publishes with
  `{expected_fingerprint,geometry_reviewed:true,routes_reviewed:true,floor_links_reviewed:true}`.
  The graph must declare `metadata.venue_id` equal to its graph ID. A changed candidate
  invalidates the fingerprint (409). Publication retains a separate immutable receipt
  and advances the public snapshot. Later worker output cannot overwrite that release.
- The app's explicit **Find places** action uploads a fresh immutable package for the
  saved capture and polls `GET /scans/{id}/analysis`. Run the separate Python worker
  in watch mode (`python -m inview_worker watch --interval 15` with the backend URL
  and processing token); Rust scene generation alone does not run the semantic
  pipeline. See [worker/README.md](worker/README.md) for setup. Suggestions retain
  source evidence and require individual Keep or Drop decisions. Kept places use
  stable IDs and preserve volunteer-added points; server output never replaces
  the local map geometry.

### Building routes (3D, multi-path)

`POST /api/buildings/{id}/routes` (or `POST /scans/{id}/routes` for one scan) returns
several distinct routes between two points, ready to draw floor by floor the way
indoor maps do. The building scope composes every aligned scan's `<scan>-nav` graph
(the published snapshot if one exists, else the worker candidate) into the reference
scan's frame, joins overlapping scans at `scan_seam` edges, clusters floors from node
heights (`L0` upward), and links floors with connectors. Connectors come from the
graph's transitions, from pairing `elevator`/`stairs`/`escalator` places and `stairs`
hazards across floors, and from `POST /api/buildings/{id}/connectors`
(`{"id","kind":"elevator|stairs|escalator|ramp","from_m":[x,y,z],"to_m":[x,y,z],"name"?,"estimated_seconds"?}`
in building-frame meters).

```json
{"from": {"place_id": "entrance"},
 "to": {"position_m": [12.3, 3.5, -4.1], "level_id": "L1"},
 "profiles": ["fastest", "accessible"], "alternatives": 2, "version": 4, "speed_mps": 1.2}
```

Each endpoint is exactly one of `place_id`, `node_id` (`<scan>:<node>`), `position_m`
(with optional `level_id`), or `latitude`+`longitude` (with optional `level_id`; needs
the reference scan's georef). Positions snap to the nearest graph node within 5 m on
their floor. Profiles are `fastest`, `accessible` (step-free, ≥ 0.915 m clear, slope
≤ 1:12) and `low_vision` (avoids hazards and narrow passages). Alternatives come from
Yen's k-shortest paths. A path sharing at least 70% of its length with one already
kept is dropped, a path found by several profiles carries all their `labels`, and at
most 5 routes are returned.

Each route has:
- `accessibility.status`, one of:
  - `not_accessible`: some edge or feature fails a criterion; `blocking` lists it;
  - `unverified`: no failures, but something is unmeasured, such as elevator width or
    a scan seam; `unverified` lists it;
  - `accessible`.
- `features`, each with:
  - a stable `id` (`f1`…);
  - a `type`, one of `door`, `stairs`, `elevator`, `escalator`, `ramp`,
    `narrow_passage`, `scan_seam`, a hazard kind, `sign`, `landmark`, or
    `destination`;
  - `position_m`, `level_id`/`to_level_id`, `distance_along_m`, and `accessible`;
  - `refs` back to the source place, hazard, door, sign and edge IDs.
- `legs`: `walk` legs per floor, each with a simplified `polyline_m`, a
  `polyline_lonlat` when georeferenced, and `bbox_m`. `connector` legs sit between
  floors.
- `steps`: machine-readable `maneuver` codes (`depart`, `slight_left`…`u_turn`,
  `enter_elevator`/`exit_elevator`, `stairs_up`/`stairs_down`,
  `escalator_up`/`escalator_down`, `ramp_up`/`ramp_down`, `pass_door`, `arrive`),
  plus an English `instruction` anchored to nearby signs, and `feature_ids`.

`unreachable` explains profiles with no route. The error codes are:
- `endpoint_not_found` (404);
- `no_route` (422);
- `navigation_data_missing` (409): no processed nav graph yet;
- `database_unavailable` (503): building scope without PostgreSQL.

Results are screening output from captured evidence, not certified accessible routes.

#### Server routes and the app's on-device planner

The app keeps its own planner: an A* search over a 10 cm occupancy grid of the floor it has
measured, at clearances of 0.45, 0.3 and 0.15 m. Measured on the same scans, in Release builds
on an Apple-silicon Mac:

| | Device grid | Server graph |
|---|---|---|
| Demo room, Reception → Meeting room | 0.3 ms · 14.96 m from the real start | 1 ms over local HTTP (~500 ms via ngrok) · 16.9 m, starting 1.8 m away at the nearest node |
| Student Center floor 2 (491×432 grid) | 16 ms to build · 3.9 ms per route · 1.7 ms reroute | n/a (no nav graph) |
| 625-node graph · 3 floors / 1,875 · 5 floors / 10,125 | n/a (one floor only) | 2.5 ms · 4.3 ms · 20 ms (plan with alternatives) |

The two divide the work as follows:
- **Server:** topology and meaning (floors, connectors, features, accessibility verdicts,
  alternatives).
- **Device:** exact geometry on its own floor, live obstacles, and offline use.
- **`RouteReconciler`** (AccessCore) redraws each server walk leg on the device's floor from
  where the person actually stands, then compares distances (`confirmed`, `shorterOnDevice`,
  `longerOnDevice`, `blockedOnDevice`). It reports how much of the server path lies on measured
  free floor. It flags `deviceFoundWiderPath` when the server judged a route too narrow but the
  device routed it with 0.9 m of clearance. It never upgrades the server's accessibility status.

On graphs over 1,500 nodes, alternatives use the penalty method, because Yen's spur searches took
1.3 s at 10k nodes.

### Nearby search ("where is McDonald's?")

`POST /api/buildings/{id}/nearby` (or `POST /scans/{id}/nearby`) lists what is around a
point, the way a maps app answers "restrooms near me".

```json
{"at": {"place_id": "entrance"}, "query": "mcdonalds", "categories": [],
 "kinds": ["place", "sign", "connector"], "radius_m": 200, "limit": 25,
 "same_level_only": false, "heading_degrees": 0, "version": 4, "speed_mps": 1.2}
```

`at` takes the same endpoint forms as routes. The parameters are:
- `query` matches names, sign text and categories. It ignores case and punctuation
  ("McDonald's" = "mcdonalds") and knows everyday words ("bathroom" finds `restroom`,
  "lift" finds `elevator`).
- `kinds` also accepts `door` and `hazard`.
- A sign repeating a nearby place's name is folded into that place.
- Connectors already backed by a place are listed through that place, along with
  the floors they serve.

Each result has:
- `kind` and `category`;
- `name`, `position_m`, `lon_lat`, `level_id` and `level_delta`;
- `distance_m` (straight line), plus `walking_distance_m` and `walking_duration_s` over
  the navigation graph, including other floors;
- `accessible_route`: the screening of the best step-free path, one of `accessible`,
  `unverified`, `not_accessible`, or `none`;
- `bearing_deg`: true north with a georef, else the frame's −Z (see
  `bearing_reference`), plus `compass` and, given `heading_degrees`,
  `relative_direction` (`ahead`, `right`, `behind`, or `left`);
- `serves_level_ids` for elevators, stairs and similar connectors;
- `refs` back to the source records;
- `route_to`, ready to pass as `to` in a routes request.

Results are ordered by name match first, then walking distance, with unreachable
results last.

## Operational limits

Use one backend process per storage directory. Geometry endpoints share a
four-request admission limit; excess requests return 503 `processing_busy`.
Continuous reconstruction permits two builders at once. SIGINT and SIGTERM drain
active HTTP requests. Accepted durable writes finish even if the client disconnects.

Back up the scan, stream and product directories together with the database.
The executable uses durable default directories even when their environment
variables are unset; isolated `AppState::default()` scan/graph stores are in-memory.
The [Vultr configuration](infra/README.md) provides HTTPS and container-persistent
scan, stream and account/submission files; it does not provision a database. Docker
runs from `/data`, so the default relative `INVIEW_PRODUCT_DIR` (`data/product`)
stores account snapshots at `/data/data/product` inside the persistent mount.
Preserve this default when updating an existing instance to retain its accounts.

Geometry validation checks data consistency, not real-world wall clearance,
scan alignment, connector identity or accessibility; map review must establish
those properties. The `/scans` prototype uses supplied object labels. Continuous
`/streams` scans can use the separate local furniture recognizer; uncertain results
retain measured shapes. Original capture JSON, including unknown fields, and package
sidecars remain immutable. Routing returns planning geometry; live positioning,
speech and rerouting run on the phone. Active journeys do not yet track server graph
revisions. Database integration tests require an explicitly configured test database.

## Checks

```sh
cargo fmt --check
cargo test --locked
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
