//! Versioned scan-to-building alignment. RoomPlan and LiDAR remain in the same ARKit scan frame.
//! Postgres stores small map records and timestamped evidence; raw scan assets stay separate.
use axum::{
    Json,
    extract::{Path, Query, State, rejection::JsonRejection},
    http::StatusCode,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{PgPool, Row, postgres::PgPoolOptions};
use uuid::Uuid;

use crate::{
    AppState,
    error::ApiError,
    geometry::{Transform, finite},
    map_frame::{self, ControlPoint, Fit},
    store::StoredScan,
};

const MIGRATION: &str = include_str!("../migrations/001_building_maps.sql");

pub async fn connect(
    url: &str,
    require_timescale: bool,
) -> Result<PgPool, Box<dyn std::error::Error + Send + Sync>> {
    let pool = PgPoolOptions::new().max_connections(5).connect(url).await?;
    let mut tx = pool.begin().await?;
    // Coordinate startup across workers. CREATE IF NOT EXISTS is not sufficient for concurrent DDL.
    sqlx::query("SELECT pg_advisory_xact_lock(428719, 1)")
        .execute(&mut *tx)
        .await?;
    sqlx::raw_sql(MIGRATION).execute(&mut *tx).await?;
    let available: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name='timescaledb')",
    )
    .fetch_one(&mut *tx)
    .await?;
    if available {
        sqlx::query("CREATE EXTENSION IF NOT EXISTS timescaledb")
            .execute(&mut *tx)
            .await?;
        sqlx::query("SELECT create_hypertable('pose_observations', 'observed_at', if_not_exists => TRUE, migrate_data => TRUE)")
            .execute(&mut *tx).await?;
        let hypertable: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM timescaledb_information.hypertables
             WHERE hypertable_schema = current_schema() AND hypertable_name = 'pose_observations')",
        )
        .fetch_one(&mut *tx)
        .await?;
        if !hypertable {
            return Err("pose_observations was not converted to a TimescaleDB hypertable".into());
        }
        tracing::info!("Timestamped pose observations use a TimescaleDB hypertable");
    } else if require_timescale {
        return Err(
            "INVIEW_REQUIRE_TIMESCALE=1 but the TimescaleDB extension is unavailable".into(),
        );
    }
    tx.commit().await?;
    Ok(pool)
}

fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "database_unavailable",
        "Set INVIEW_DATABASE_URL to use building maps.",
    )
}
fn failure(error: sqlx::Error) -> ApiError {
    tracing::error!(%error, "Building database operation failed");
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "database_error",
        "Building database is unavailable.",
    )
}
fn conflict(message: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, "alignment_conflict", message)
}
fn not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "building_not_found",
        "Building not found.",
    )
}
fn db(state: &AppState) -> Result<&PgPool, ApiError> {
    state.maps.as_ref().ok_or_else(unavailable)
}
fn scan_missing() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "scan_not_found",
        "Scan must be uploaded before it can be aligned.",
    )
}
fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateBuilding {
    name: String,
    reference_capture_id: String,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AlignCapture {
    capture_id: String,
    expected_version: i32,
    method: String,
    #[serde(default)]
    pairs: Option<Vec<ControlPoint>>,
    #[serde(default)]
    building_marker: Option<Transform>,
    #[serde(default)]
    scan_marker: Option<Transform>,
}
#[derive(Debug, Deserialize, Default)]
pub struct VersionQuery {
    version: Option<i32>,
}
#[derive(Debug, Deserialize, Default)]
pub struct ObservationQuery {
    version: Option<i32>,
    limit: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Alignment {
    capture_id: String,
    version: i32,
    method: String,
    status: String,
    transform4x4_column_major: Vec<f64>,
    rms_meters: Option<f64>,
    max_error_meters: Option<f64>,
    created_at: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Building {
    id: String,
    name: String,
    reference_capture_id: String,
    created_at: String,
    version: i32,
    scan_count: usize,
    capture_ids: Vec<String>,
    frame: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    alignments: Option<Vec<Alignment>>,
}
fn frame() -> Value {
    json!({"axes":"X/Z horizontal, Y up", "units":"meters", "origin":"reference scan ARKit world"})
}

async fn summary(pool: &PgPool, row: &sqlx::postgres::PgRow) -> Result<Building, ApiError> {
    let id: String = row.get("id");
    let captures: Vec<String> = sqlx::query_scalar(
        "SELECT capture_id FROM capture_buildings WHERE building_id=$1 ORDER BY capture_id",
    )
    .bind(&id)
    .fetch_all(pool)
    .await
    .map_err(failure)?;
    Ok(Building {
        id,
        name: row.get("name"),
        reference_capture_id: row.get("reference_capture"),
        created_at: row.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
        version: row.get("version"),
        scan_count: captures.len(),
        capture_ids: captures,
        frame: frame(),
        alignments: None,
    })
}
async fn snapshot(pool: &PgPool, id: &str, version: Option<i32>) -> Result<Building, ApiError> {
    if !valid_id(id) {
        return Err(not_found());
    }
    let row = sqlx::query("SELECT * FROM buildings WHERE id=$1")
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(failure)?
        .ok_or_else(not_found)?;
    let mut result = summary(pool, &row).await?;
    let at = version.unwrap_or(result.version);
    if !(1..=result.version).contains(&at) {
        return Err(ApiError::invalid("Map version does not exist."));
    }
    let rows = sqlx::query("SELECT a.* FROM alignments a JOIN
         (SELECT capture_id,MAX(version) AS version FROM alignments WHERE building_id=$1 AND version<=$2 GROUP BY capture_id) latest
         ON a.capture_id=latest.capture_id AND a.version=latest.version
         WHERE a.building_id=$1 ORDER BY a.created_at,a.capture_id")
        .bind(id).bind(at).fetch_all(pool).await.map_err(failure)?;
    result.version = at;
    result.capture_ids = rows.iter().map(|r| r.get("capture_id")).collect();
    result.scan_count = rows.len();
    result.alignments = Some(
        rows.into_iter()
            .map(|r| Alignment {
                capture_id: r.get("capture_id"),
                version: r.get("version"),
                method: r.get("method"),
                status: r.get("status"),
                transform4x4_column_major: r
                    .get::<Value, _>("transform")
                    .as_array()
                    .expect("validated transform")
                    .iter()
                    .map(|x| x.as_f64().expect("finite transform"))
                    .collect(),
                rms_meters: r.get("rms_m"),
                max_error_meters: r.get("max_error_m"),
                created_at: r.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
            })
            .collect(),
    );
    Ok(result)
}

async fn append_poses(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    scan: &StoredScan,
    id: &str,
    scan_id: &str,
    version: i32,
    fit: &Fit,
    observed_origin: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    let track = scan.camera_track();
    let first = track.first().map(|p| p.timestamp_seconds).unwrap_or(0.);
    // Anchor ARKit-relative times to the iPhone wall clock when location context recorded it.
    let device_origin = track.iter().find_map(|p| {
        let unix = p.unix_seconds? - (p.timestamp_seconds - first);
        DateTime::<Utc>::from_timestamp_millis((unix * 1000.) as i64)
    });
    let observed_origin = device_origin.unwrap_or(observed_origin);
    for (index, frame) in track.iter().enumerate() {
        let seconds = (frame.timestamp_seconds - first).max(0.);
        if !seconds.is_finite() || seconds > 7. * 86400. {
            continue;
        }
        let Some(offset) = Duration::try_milliseconds((seconds * 1000.) as i64) else {
            continue;
        };
        let pos = fit
            .transform
            .point(frame.map_from_camera.point([0., 0., 0.]));
        sqlx::query(
            "INSERT INTO pose_observations
            (observed_at,building_id,capture_id,map_version,frame_index,x_m,y_m,z_m,tracking_state)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT DO NOTHING",
        )
        .bind(observed_origin + offset)
        .bind(id)
        .bind(scan_id)
        .bind(version)
        .bind(index as i32)
        .bind(pos[0])
        .bind(pos[1])
        .bind(pos[2])
        .bind(Option::<String>::None)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

pub async fn list(State(state): State<AppState>) -> Result<Json<Vec<Building>>, ApiError> {
    let pool = db(&state)?;
    let rows = sqlx::query("SELECT * FROM buildings ORDER BY created_at DESC")
        .fetch_all(pool)
        .await
        .map_err(failure)?;
    let mut out = Vec::with_capacity(rows.len());
    for row in &rows {
        out.push(summary(pool, row).await?);
    }
    Ok(Json(out))
}
pub async fn get(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<VersionQuery>,
) -> Result<Json<Building>, ApiError> {
    Ok(Json(snapshot(db(&state)?, &id, q.version).await?))
}
pub async fn create(
    State(state): State<AppState>,
    payload: Result<Json<CreateBuilding>, JsonRejection>,
) -> Result<(StatusCode, Json<Building>), ApiError> {
    let Json(input) = payload.map_err(|e| ApiError::invalid(e.body_text()))?;
    let name = input.name.trim();
    if name.is_empty() || name.len() > 120 {
        return Err(ApiError::invalid(
            "Building name must contain 1–120 characters.",
        ));
    }
    let scan = state
        .scans
        .get(&input.reference_capture_id)
        .await
        .ok_or_else(scan_missing)?;
    let pool = db(&state)?;
    let id = Uuid::new_v4().simple().to_string();
    let timestamp = Utc::now();
    let mut tx = pool.begin().await.map_err(failure)?;
    let existing: Option<String> =
        sqlx::query_scalar("SELECT building_id FROM capture_buildings WHERE capture_id=$1")
            .bind(&input.reference_capture_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(failure)?;
    if existing.is_some() {
        return Err(conflict("This scan already belongs to a building."));
    }
    sqlx::query("INSERT INTO buildings(id,name,reference_capture,created_at,version) VALUES ($1,$2,$3,$4,1)")
        .bind(&id).bind(name).bind(&input.reference_capture_id).bind(timestamp).execute(&mut *tx).await.map_err(failure)?;
    sqlx::query("INSERT INTO capture_buildings(capture_id,building_id) VALUES ($1,$2)")
        .bind(&input.reference_capture_id)
        .bind(&id)
        .execute(&mut *tx)
        .await
        .map_err(|e| insert_error(e, "This scan already belongs to a building."))?;
    sqlx::query("INSERT INTO alignments(building_id,capture_id,version,method,status,transform,rms_m,max_error_m,evidence,created_at)
        VALUES ($1,$2,1,'reference','reference',$3,0,0,$4,$5)")
        .bind(&id).bind(&input.reference_capture_id).bind(json!(map_frame::IDENTITY.0)).bind(json!({})).bind(timestamp)
        .execute(&mut *tx).await.map_err(failure)?;
    append_poses(
        &mut tx,
        &scan,
        &id,
        &input.reference_capture_id,
        1,
        &Fit {
            transform: map_frame::IDENTITY,
            rms_m: Some(0.),
            max_error_m: Some(0.),
        },
        timestamp,
    )
    .await
    .map_err(failure)?;
    tx.commit().await.map_err(failure)?;
    Ok((StatusCode::CREATED, Json(snapshot(pool, &id, None).await?)))
}
fn insert_error(error: sqlx::Error, description: &'static str) -> ApiError {
    if let sqlx::Error::Database(ref e) = error
        && e.is_unique_violation()
    {
        return conflict(description);
    }
    failure(error)
}
pub async fn align(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<AlignCapture>, JsonRejection>,
) -> Result<(StatusCode, Json<Building>), ApiError> {
    let Json(input) = payload.map_err(|e| ApiError::invalid(e.body_text()))?;
    if !valid_id(&id) {
        return Err(not_found());
    }
    let scan = state
        .scans
        .get(&input.capture_id)
        .await
        .ok_or_else(scan_missing)?;
    let fit = match input.method.as_str() {
        "control_points" => map_frame::fit_points(input.pairs.as_deref().unwrap_or(&[])),
        "marker" => match (input.building_marker, input.scan_marker) {
            (Some(b), Some(s)) => map_frame::fit_marker(b, s),
            _ => Err("Both marker-to-frame transforms are required.".into()),
        },
        _ => Err("Alignment method must be control_points or marker.".into()),
    }
    .map_err(ApiError::invalid)?;
    let pool = db(&state)?;
    let mut tx = pool.begin().await.map_err(failure)?;
    let row =
        sqlx::query("SELECT version, reference_capture FROM buildings WHERE id=$1 FOR UPDATE")
            .bind(&id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(failure)?
            .ok_or_else(not_found)?;
    let version: i32 = row.get("version");
    if input.expected_version != version {
        return Err(conflict(format!(
            "Map version changed; reload version {version}."
        )));
    }
    if row.get::<String, _>("reference_capture") == input.capture_id {
        return Err(conflict("The reference scan defines the building frame."));
    }
    let existing: Option<String> =
        sqlx::query_scalar("SELECT building_id FROM capture_buildings WHERE capture_id=$1")
            .bind(&input.capture_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(failure)?;
    if existing.as_deref().is_some_and(|other| other != id) {
        return Err(conflict("This scan belongs to another building."));
    }
    if existing.is_none() {
        sqlx::query("INSERT INTO capture_buildings(capture_id,building_id) VALUES ($1,$2)")
            .bind(&input.capture_id)
            .bind(&id)
            .execute(&mut *tx)
            .await
            .map_err(|e| insert_error(e, "This scan belongs to another building."))?;
    }
    let next = version + 1;
    let timestamp = Utc::now();
    let evidence = match input.method.as_str() {
        "control_points" => json!({"pairs": input.pairs}),
        _ => json!({"buildingMarker": input.building_marker, "scanMarker": input.scan_marker}),
    };
    sqlx::query("INSERT INTO alignments(building_id,capture_id,version,method,status,transform,rms_m,max_error_m,evidence,created_at)
        VALUES ($1,$2,$3,$4,'provisional',$5,$6,$7,$8,$9)")
        .bind(&id).bind(&input.capture_id).bind(next).bind(&input.method).bind(json!(fit.transform.0))
        .bind(fit.rms_m).bind(fit.max_error_m).bind(evidence).bind(timestamp)
        .execute(&mut *tx).await.map_err(failure)?;
    // Revised alignments use the first observation timestamp for the same scan, not a fake new visit.
    let origin: Option<DateTime<Utc>> = sqlx::query_scalar(
        "SELECT MIN(observed_at) FROM pose_observations WHERE building_id=$1 AND capture_id=$2",
    )
    .bind(&id)
    .bind(&input.capture_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(failure)?;
    append_poses(
        &mut tx,
        &scan,
        &id,
        &input.capture_id,
        next,
        &fit,
        origin.unwrap_or(timestamp),
    )
    .await
    .map_err(failure)?;
    sqlx::query("UPDATE buildings SET version=$1 WHERE id=$2")
        .bind(next)
        .bind(&id)
        .execute(&mut *tx)
        .await
        .map_err(failure)?;
    tx.commit().await.map_err(failure)?;
    Ok((StatusCode::CREATED, Json(snapshot(pool, &id, None).await?)))
}

pub async fn observations(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<ObservationQuery>,
) -> Result<Json<Value>, ApiError> {
    let pool = db(&state)?;
    let building = snapshot(pool, &id, q.version).await?;
    let limit = q.limit.unwrap_or(500);
    if !(1..=5000).contains(&limit) {
        return Err(ApiError::invalid("Limit must be 1–5000."));
    }
    let rows = sqlx::query("SELECT p.observed_at,p.capture_id,p.map_version,p.frame_index,p.x_m,p.y_m,p.z_m,p.tracking_state
        FROM pose_observations p JOIN (
            SELECT capture_id,MAX(version) AS version FROM alignments
            WHERE building_id=$1 AND version<=$2 GROUP BY capture_id
        ) a ON a.capture_id=p.capture_id AND a.version=p.map_version
        WHERE p.building_id=$1 ORDER BY p.observed_at DESC LIMIT $3")
        .bind(&id).bind(building.version).bind(limit).fetch_all(pool).await.map_err(failure)?;
    let poses: Vec<Value> = rows.iter().map(|r| json!({
        "observedAt": r.get::<DateTime<Utc>, _>("observed_at").to_rfc3339(),
        "captureId": r.get::<String, _>("capture_id"), "mapVersion": r.get::<i32, _>("map_version"),
        "frameIndex": r.get::<i32, _>("frame_index"),
        "positionMeters": [r.get::<f64, _>("x_m"), r.get::<f64, _>("y_m"), r.get::<f64, _>("z_m")],
        "trackingState": r.get::<Option<String>, _>("tracking_state"),
    })).collect();
    Ok(Json(
        json!({"buildingId": id, "mapVersion": building.version, "poses": poses,
        "timeSource": "arkit_relative_anchored_to_device_clock_or_ingest"}),
    ))
}

/// Top-down `(X, Z)` preview of aligned camera paths and sampled mesh vertices. These are
/// observations in the building frame, not verified walkable space or a floor plan.
pub async fn overview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<VersionQuery>,
) -> Result<Json<Value>, ApiError> {
    let building = snapshot(db(&state)?, &id, q.version).await?;
    let mut inputs = Vec::new();
    for alignment in building.alignments.iter().flatten().take(40) {
        // A removed source scan stays in alignment history but contributes no preview.
        if let Some(scan) = state.scans.get(&alignment.capture_id).await {
            let mut transform = map_frame::IDENTITY;
            transform
                .0
                .copy_from_slice(&alignment.transform4x4_column_major);
            inputs.push((
                alignment.capture_id.clone(),
                alignment.status.clone(),
                alignment.method.clone(),
                transform,
                scan,
            ));
        }
    }
    let observations = tokio::task::spawn_blocking(move || {
        inputs
            .into_iter()
            .map(|(capture_id, status, method, transform, scan)| {
                let xz = |p: [f64; 3], digits: f64| {
                    let q = transform.point(p);
                    [
                        (q[0] * digits).round() / digits,
                        (q[2] * digits).round() / digits,
                    ]
                };
                let track = scan.camera_track();
                let path: Vec<[f64; 2]> = track
                    .iter()
                    .step_by(track.len().div_ceil(500).max(1))
                    .map(|f| f.map_from_camera.point([0., 0., 0.]))
                    .filter(|p| finite(*p))
                    .map(|p| xz(p, 1000.))
                    .collect();
                let vertices: Vec<[f64; 3]> = crate::raw_lidar::native_mesh_vertices(&scan)
                    .map(|v| v.into_iter().map(|p| p.map(f64::from)).collect())
                    .unwrap_or_else(|| {
                        scan.bundle
                            .meshes
                            .iter()
                            .flat_map(|m| m.vertices.iter().map(|v| m.map_from_anchor.point(*v)))
                            .collect()
                    });
                let samples: Vec<[f64; 2]> = vertices
                    .iter()
                    .step_by(vertices.len().div_ceil(1800).max(1))
                    .map(|p| xz(*p, 100.))
                    .collect();
                json!({"captureId": capture_id, "status": status, "method": method,
                       "pathXZ": path, "surfaceSamplesXZ": samples})
            })
            .collect::<Vec<_>>()
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "Building overview task failed");
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "processing_failed",
            "Building overview could not be prepared.",
        )
    })?;
    Ok(Json(json!({
        "building": building,
        "observations": observations,
        "notice": "Mesh samples and phone paths are observations, NOT verified walkable space or localization.",
    })))
}
