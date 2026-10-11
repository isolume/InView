-- Volunteer-registered vertical links (elevator, stairs, escalator, ramp) in the building frame.
-- They complement connectors inferred from scan places and hazards when routes are composed.
CREATE TABLE IF NOT EXISTS building_connectors (
    building_id TEXT NOT NULL REFERENCES buildings(id),
    id TEXT NOT NULL,
    kind TEXT NOT NULL,
    from_m JSONB NOT NULL,
    to_m JSONB NOT NULL,
    name TEXT,
    estimated_seconds DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (building_id, id)
);
