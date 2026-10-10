-- Stable building frame + immutable per-version scan alignments.
-- Keep large archives and render assets on disk/object storage, not in PostgreSQL.
CREATE TABLE IF NOT EXISTS buildings (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    reference_capture TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    version INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS capture_buildings (
    capture_id TEXT PRIMARY KEY,
    building_id TEXT NOT NULL REFERENCES buildings(id)
);
CREATE INDEX IF NOT EXISTS capture_buildings_by_building ON capture_buildings(building_id);
CREATE TABLE IF NOT EXISTS alignments (
    building_id TEXT NOT NULL REFERENCES buildings(id),
    capture_id TEXT NOT NULL REFERENCES capture_buildings(capture_id),
    version INTEGER NOT NULL,
    method TEXT NOT NULL,
    status TEXT NOT NULL,
    transform JSONB NOT NULL,
    rms_m DOUBLE PRECISION,
    max_error_m DOUBLE PRECISION,
    evidence JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (building_id, capture_id, version)
);
CREATE INDEX IF NOT EXISTS alignment_history ON alignments(building_id, version);
-- Timestamped pose evidence, recorded in the building frame at a specific map version.
-- A later realignment appends a new version rather than moving historical observations.
CREATE TABLE IF NOT EXISTS pose_observations (
    observed_at TIMESTAMPTZ NOT NULL,
    building_id TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    map_version INTEGER NOT NULL,
    frame_index INTEGER NOT NULL,
    x_m DOUBLE PRECISION NOT NULL,
    y_m DOUBLE PRECISION NOT NULL,
    z_m DOUBLE PRECISION NOT NULL,
    tracking_state TEXT,
    PRIMARY KEY (observed_at, building_id, capture_id, map_version, frame_index)
);
CREATE INDEX IF NOT EXISTS poses_for_building ON pose_observations(building_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS poses_for_scan ON pose_observations(building_id, capture_id, map_version, observed_at);
