# Building maps — Rust/PostgreSQL merge (first slice)

This is **additive** to the RoomPlan-first `/scans` and `/scan-packages` APIs. It does not replace the iOS capture format or reset its shared ARKit session. A scan is an observation; a building has a stable, arbitrary Y-up reference frame (meters). Indoor GPS is not used for precise alignment.

## Run

The maintained launcher is `backend/start-server.sh`. It requires an ignored `.secrets/api-token` (64 hex characters from `openssl rand -hex 32`), loads `.secrets/tigerdata-url` with mandatory TimescaleDB when present, and otherwise requires the **explicit** `INVIEW_ALLOW_LOCAL_POSTGRES=1` development override. It builds the Rust binary and uses the persistent scan directory. For the current iPhone tunnel, paste the URL into Scan processing settings and paste the token from `backend/.secrets/api-token` into its secure Access token field. Never put the token in a URL or commit it.

```sh
cd backend
# Local PostgreSQL development; database must already exist:
INVIEW_ALLOW_LOCAL_POSTGRES=1 ./start-server.sh  # only local PostgreSQL, NOT TigerData
# For TigerData, use its TLS URL, typically with ?sslmode=require:
./start-server.sh  # after placing credentials in .secrets/tigerdata-url
```

To complete live TigerData validation, provide **two** URLs in the ignored, mode-700 `backend/.secrets/` directory: `tigerdata-url` for the app and `tigerdata-test-url` for a separate writable test database. Each should be a complete PostgreSQL URI with `sslmode=require`. Never point the integration test at production; it creates and drops a schema. No TigerData URL is currently configured, so a real cloud connection cannot yet be claimed.

Do not commit the database URL or token. Remote operation requires HTTPS at the reverse proxy and `INVIEW_API_TOKEN`; the Rust server refuses non-loopback binding without a token. The iOS Backend Settings stores the access token in the device Keychain. Keep the token outside URLs and logs. The startup applies `migrations/001_building_maps.sql` and creates a Timescale hypertable for `pose_observations` when TimescaleDB is available. `INVIEW_REQUIRE_TIMESCALE=1` fails startup rather than silently using a normal PostgreSQL table. The local PostgreSQL instance used for development does **not** have TimescaleDB installed; hypertable DDL still needs validation on TigerData. If `INVIEW_DATABASE_URL` is unset, existing scan/routing APIs continue working, but `/api/buildings` returns 503. If PostgreSQL is configured, `INVIEW_SCAN_DIR` is mandatory; startup fails if any persisted scan is corrupt instead of silently losing map source data.

Raw capture assets and RoomPlan JSON persist as **immutable files** in `INVIEW_SCAN_DIR`, separate from PostgreSQL. The scan store loads the originals and sidecars at startup, making mapped scans and scene processing available after restart; no large archive is saved in TigerData. Files use SHA-256 filenames derived from scan IDs; uploads are staged and atomically linked into place. Back up the database **and** the scan directory together. Existing in-memory-only uploads made before this change must be re-uploaded to the durable server. Graph storage and any verified navigation package are still not persistent.

## API

After `POST /scan-packages` (or `POST /scans`) has loaded a scan:

- `POST /api/buildings` with `{"name":"Engineering Hall","referenceCaptureId":"<scan-id>"}`. Sets this scan's shared ARKit frame as the building reference, version 1.
- `GET /api/buildings` and `GET /api/buildings/{id}?version=1`. A pinned version returns the latest alignment **at or before** that version for each scan. The reference transform remains identity.
- `POST /api/buildings/{id}/alignments` with `captureId`, `expectedVersion`, `method` (`control_points` or `marker`) and method-specific evidence. Every successful alignment increments the version; earlier versions remain queryable. Other buildings cannot claim the same scan. New alignments are **provisional**, not verified accessible navigation geometry.
- `GET /api/buildings/{id}/observations?version=1&limit=500`: timestamped camera path in the building frame from frames in the active alignment of the requested version. Poses come from the package manifest's complete observation list (falling back to `capture.json` frames). `timeSource: arkit_relative_anchored_to_device_clock_or_ingest`: ARKit-relative frame times are anchored to the iPhone wall clock recorded with the capture's location context when present, otherwise to ingestion time. Re-alignment retains the initial observation timestamp for that scan.
- `GET /api/buildings/{id}/overview?version=1`: top-down `(X, Z)` preview per aligned scan in that map version (up to 40): `pathXZ` (≤500 sampled camera positions) and `surfaceSamplesXZ` (≤1800 mesh vertices, native ARKit mesh sidecar when present, otherwise the portable bundle meshes). Scans no longer on this server are omitted but stay in alignment history. The Studio building card draws it. This is a preview of observations, **not** a floor plan or walkable space.

### Control points

Provide at least two, ideally three or more, matched known XYZ locations, in meters (Y up):

```json
{
  "captureId": "<second-scan-id>", "expectedVersion": 1,
  "method": "control_points",
  "pairs": [
    {"scan": [0, 0, 0], "building": [10, 2, 20]},
    {"scan": [1, 0, 0], "building": [10, 2, 21]},
    {"scan": [0, 0, 1], "building": [9, 2, 20]}
  ]
}
```

This estimates **yaw only** plus XYZ translation; horizontal control points must be spatially distinct. Mismatches above 0.35 m RMS or 0.60 m maximum residual are rejected. Passing these thresholds does not establish calibrated position accuracy.

### Marker pose

Send `buildingMarker` and `scanMarker`, both 16-number **column-major marker-to-frame** rigid transforms, plus `captureId`, `expectedVersion`, and `"method":"marker"`. The backend computes `T_building_from_scan = T_building_from_marker × inverse(T_scan_from_marker)`; it does **not** detect a marker or infer its pose from a photo. It rejects scale, reflection, non-finite matrices, and unknown scan IDs.

## Tests

`CARGO_TARGET_DIR=/tmp/inview-rust-target cargo test` runs ordinary tests. For PostgreSQL integration tests, set `INVIEW_TEST_DATABASE_URL='postgresql://localhost/inview_dev'`. To verify an actual TigerData instance, point `INVIEW_TEST_DATABASE_URL` to a **separate writable test database**, set `INVIEW_TEST_REQUIRE_TIMESCALE=1`, and run `cargo test --test buildings`. The test must be permitted to create/drop a schema; it verifies both TLS through `pg_stat_ssl` and the hypertable through `timescaledb_information.hypertables`. Never use your production database as this test target. Each test uses its own disposable schema. This repository path contains a `:`; a target dir outside the repository avoids macOS `DYLD_FALLBACK_LIBRARY_PATH` build failures.
