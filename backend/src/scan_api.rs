use axum::{
    Json,
    body::Bytes,
    extract::{Path, State, rejection::JsonRejection},
    http::StatusCode,
    response::Html,
};
use serde_json::Value;

use crate::{
    AppState,
    capture::ScanBundle,
    error::ApiError,
    scene::{self, ProcessingOptions, Scene},
    store::{ScanInsertError, ScanSummary, StoredScan},
};

pub async fn list(State(state): State<AppState>) -> Json<Vec<ScanSummary>> {
    Json(state.scans.list().await)
}

pub async fn upload(
    State(state): State<AppState>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<(StatusCode, Json<ScanSummary>), ApiError> {
    let Json(original) = payload.map_err(json_error)?;
    let bundle: ScanBundle = serde_json::from_value(original.clone())
        .map_err(|error| ApiError::invalid(error.to_string()))?;
    bundle.validate().map_err(ApiError::invalid)?;
    let scan = StoredScan {
        original,
        bundle,
        package_assets: None,
        package_manifest: None,
    };
    let summary = scan.summary();
    state.scans.insert(scan, None).await.map_err(insert_error)?;
    Ok((StatusCode::CREATED, Json(summary)))
}

/// Accepts the iOS-produced uncompressed `.inviewscan.tar`. Entries are validated in-memory,
/// never extracted to disk, before `capture.json` enters the normal immutable scan pipeline.
pub async fn upload_package(
    State(state): State<AppState>,
    payload: Bytes,
) -> Result<(StatusCode, Json<ScanSummary>), ApiError> {
    let permit = state.processing_permit()?;
    let (package, archive) = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        crate::scan_package::decode(&payload).map(|package| (package, payload.to_vec()))
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "Scan package decoding task failed");
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "processing_failed",
            "The scan package could not be decoded.",
        )
    })?
    .map_err(ApiError::invalid)?;
    let scan = StoredScan {
        original: package.original,
        bundle: package.bundle,
        package_assets: Some(package.assets),
        package_manifest: package.manifest,
    };
    let summary = scan.summary();
    state
        .scans
        .insert(scan, Some(archive))
        .await
        .map_err(insert_error)?;
    Ok((StatusCode::CREATED, Json(summary)))
}

pub async fn original(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let scan = state.scans.get(&id).await.ok_or_else(missing)?;
    Ok(Json(scan.original.clone()))
}

pub async fn default_scene(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Scene>, ApiError> {
    build_scene(state, id, ProcessingOptions::default()).await
}

pub async fn process(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<ProcessingOptions>, JsonRejection>,
) -> Result<Json<Scene>, ApiError> {
    let Json(options) = payload.map_err(json_error)?;
    build_scene(state, id, options).await
}

async fn build_scene(
    state: AppState,
    id: String,
    options: ProcessingOptions,
) -> Result<Json<Scene>, ApiError> {
    options.validate().map_err(ApiError::invalid)?;
    let scan = state.scans.get(&id).await.ok_or_else(missing)?;
    let permit = state.processing_permit()?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        scene::process(&scan.bundle, options)
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "Scan processing failed");
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "processing_failed",
            "The scene could not be processed.",
        )
    })?
    .map(Json)
    .map_err(ApiError::invalid)
}

pub async fn preview() -> Html<&'static str> {
    // Like Studio, the public shell reveals no scan existence or source data.
    // Its requests for the actual capture are protected by processing authorization.
    Html(include_str!("../preview.html"))
}

fn insert_error(error: ScanInsertError) -> ApiError {
    match error {
        ScanInsertError::Exists => ApiError::new(
            StatusCode::CONFLICT,
            "scan_exists",
            "This scan already exists. Use a new id for another capture.",
        ),
        ScanInsertError::Storage(error) => {
            tracing::error!(%error, "Could not persist immutable scan");
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "scan_storage_error",
                "The scan could not be safely persisted.",
            )
        }
    }
}

fn missing() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "scan_not_found",
        "This scan is not available.",
    )
}

fn json_error(error: JsonRejection) -> ApiError {
    ApiError::new(error.status(), "invalid_json", error.body_text())
}

/// Full camera path in the shared ARKit frame (dense `camera-track.json` sidecar first, then the
/// package manifest, then portable frames).
pub async fn camera_track(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let scan = state.scans.get(&scan_id).await.ok_or_else(missing)?;
    let (track, source) = scan.camera_track_with_source();
    let poses: Vec<Value> = track
        .iter()
        .map(|p| {
            serde_json::json!({
                "timestamp_seconds": p.timestamp_seconds,
                "unix_seconds": p.unix_seconds,
                "position_m": p.map_from_camera.point([0., 0., 0.]),
                "map_from_camera": p.map_from_camera,
                "tracking": p.tracking,
                "mapping": p.mapping,
            })
        })
        .collect();
    Ok(Json(serde_json::json!({
        "scan_id": scan_id, "frame": "shared_arkit_session", "source": source, "poses": poses
    })))
}

pub async fn analysis(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    state.scans.get(&scan_id).await.ok_or_else(missing)?;
    let analysis = state.scans.analysis(&scan_id).await.ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "analysis_not_found",
            "This scan has not been processed by the analysis worker yet.",
        )
    })?;
    Ok(Json((*analysis).clone()))
}

/// Accepts worker output. It is derived and replaceable; the source capture is never modified.
pub async fn put_analysis(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(analysis) = payload.map_err(|e| ApiError::invalid(e.body_text()))?;
    state.scans.get(&scan_id).await.ok_or_else(missing)?;
    if analysis.get("schema_version").and_then(|v| v.as_u64()) != Some(1)
        || analysis.get("scan_id").and_then(|v| v.as_str()) != Some(scan_id.as_str())
        || analysis.get("frame").and_then(|v| v.as_str()) != Some("shared_arkit_session")
    {
        return Err(ApiError::invalid(
            "Analysis must be schema_version 1, name this scan_id, and use the shared_arkit_session frame.",
        ));
    }
    state
        .scans
        .put_analysis(&scan_id, analysis)
        .await
        .map_err(|error| {
            tracing::error!(%error, "Could not persist scan analysis");
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "analysis_storage_error",
                "The analysis could not be saved.",
            )
        })?;
    Ok(Json(
        serde_json::json!({"scan_id": scan_id, "stored": true}),
    ))
}

/// Parsed `package-manifest.json` for workers that need calibration, environment samples, or the
/// sidecar inventory. JSON-only uploads have no manifest.
pub async fn manifest(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let scan = state.scans.get(&scan_id).await.ok_or_else(missing)?;
    let manifest = scan.package_manifest.clone().ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "manifest_not_found",
            "This scan was uploaded without a package manifest.",
        )
    })?;
    Ok(Json(manifest))
}

/// Any immutable file from the scan package (RoomPlan original, sidecars, keyframes).
pub async fn asset(
    State(state): State<AppState>,
    Path((scan_id, filename)): Path<(String, String)>,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    let scan = state.scans.get(&scan_id).await.ok_or_else(missing)?;
    let bytes = scan
        .package_assets
        .as_ref()
        .and_then(|assets| assets.get(&filename))
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::NOT_FOUND,
                "asset_not_found",
                "This scan package has no such file.",
            )
        })?;
    let content_type = match filename.rsplit_once('.').map(|(_, ext)| ext) {
        Some("json") => "application/json",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("heic") => "image/heic",
        _ => "application/octet-stream",
    };
    Ok((
        [
            (axum::http::header::CONTENT_TYPE, content_type),
            (axum::http::header::CACHE_CONTROL, "private, no-store"),
            (axum::http::header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        Bytes::copy_from_slice(bytes),
    ))
}
