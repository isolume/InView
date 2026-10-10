use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::Value;

use crate::{
    AppState,
    error::ApiError,
    scene::Scene,
    streaming::{StreamError, StreamResult, StreamSummary},
};

pub async fn create(
    State(state): State<AppState>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<(StatusCode, Json<StreamSummary>), ApiError> {
    let Json(value) = payload.map_err(json_error)?;
    let (created, summary) = blocking(move || state.streams.create(value)).await?;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(summary),
    ))
}

pub async fn summary(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<StreamSummary>, ApiError> {
    blocking(move || state.streams.summary(&id)).await.map(Json)
}

pub async fn chunk(
    State(state): State<AppState>,
    Path((id, sequence)): Path<(String, usize)>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<Json<StreamSummary>, ApiError> {
    let Json(value) = payload.map_err(json_error)?;
    blocking(move || state.streams.append(&id, sequence, value))
        .await
        .map(Json)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FinishRequest {
    pub chunk_count: usize,
}

pub async fn finish(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<FinishRequest>, JsonRejection>,
) -> Result<Json<StreamSummary>, ApiError> {
    let Json(value) = payload.map_err(json_error)?;
    blocking(move || state.streams.finish(&id, value.chunk_count))
        .await
        .map(Json)
}

pub async fn result(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<StreamResult>, ApiError> {
    reconstruct(state, id).await.map(Json)
}

pub async fn scene(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Scene>, ApiError> {
    reconstruct(state, id)
        .await
        .map(|result| Json(result.scene))
}

async fn reconstruct(state: AppState, id: String) -> Result<StreamResult, ApiError> {
    // Return a retryable response rather than queueing arbitrarily many expensive jobs.
    let permit = state
        .streams
        .processing
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "processing_busy",
                "Two scans are already processing. Retry shortly.",
            )
        })?;
    blocking(move || {
        let _permit = permit;
        state.streams.reconstruct(&id)
    })
    .await
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, StreamError> + Send + 'static,
) -> Result<T, ApiError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| {
            tracing::error!(%error, "Stream worker failed");
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "stream_processing_failed",
                "The scan could not be processed.",
            )
        })?
        .map_err(stream_error)
}

fn stream_error(error: StreamError) -> ApiError {
    match error {
        StreamError::Invalid(message) => ApiError::invalid(message),
        StreamError::Conflict(message) => {
            ApiError::new(StatusCode::CONFLICT, "stream_conflict", message)
        }
        StreamError::Limit(message) => {
            ApiError::new(StatusCode::PAYLOAD_TOO_LARGE, "stream_limit", message)
        }
        StreamError::ResultTooLarge => ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "result_too_large",
            "This scan's model exceeds the 64 MiB result limit. A larger-scene reconstruction pipeline is required.",
        ),
        StreamError::Missing => ApiError::new(
            StatusCode::NOT_FOUND,
            "stream_not_found",
            "This scan stream is not available.",
        ),
        StreamError::Unfinished => ApiError::new(
            StatusCode::CONFLICT,
            "stream_unfinished",
            "Finish uploading the scan before requesting its model.",
        ),
        StreamError::Storage(error) => {
            tracing::error!(%error, "Stream storage failed");
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "stream_storage_failed",
                "The scan could not be saved. Retry the same upload.",
            )
        }
    }
}

fn json_error(error: JsonRejection) -> ApiError {
    ApiError::new(error.status(), "invalid_json", error.body_text())
}
