use axum::{
    Json,
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
    store::{ScanSummary, StoredScan},
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
    let scan = StoredScan { original, bundle };
    let summary = scan.summary();
    state.scans.insert(scan).await.map_err(|()| {
        ApiError::new(
            StatusCode::CONFLICT,
            "scan_exists",
            "This scan already exists. Use a new id for another capture.",
        )
    })?;
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
    tokio::task::spawn_blocking(move || scene::process(&scan.bundle, options))
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

pub async fn preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Html<&'static str>, ApiError> {
    state.scans.get(&id).await.ok_or_else(missing)?;
    Ok(Html(include_str!("../preview.html")))
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
