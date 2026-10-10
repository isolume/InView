use axum::{
    Json,
    body::Bytes,
    extract::{
        Path, State,
        rejection::{BytesRejection, JsonRejection},
    },
    http::{HeaderMap, StatusCode, header},
};
use serde::Deserialize;
use serde_json::Value;
use std::io::{Cursor, Read, Write};

use crate::{
    AppState,
    error::ApiError,
    streaming::{MAX_CHUNK_BYTES, StreamError, StreamSummary},
};

pub async fn create(
    State(state): State<AppState>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<
    (
        StatusCode,
        [(header::HeaderName, &'static str); 1],
        Json<StreamSummary>,
    ),
    ApiError,
> {
    let Json(value) = payload.map_err(json_error)?;
    let (created, summary) = blocking(move || state.streams.create(value)).await?;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        [(header::ACCEPT_ENCODING, "gzip")],
        Json(summary),
    ))
}

pub async fn summary(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<([(header::HeaderName, &'static str); 1], Json<StreamSummary>), ApiError> {
    blocking(move || state.streams.summary(&id))
        .await
        .map(|summary| ([(header::ACCEPT_ENCODING, "gzip")], Json(summary)))
}

pub async fn chunk(
    State(state): State<AppState>,
    Path((id, sequence)): Path<(String, usize)>,
    headers: HeaderMap,
    payload: Result<Bytes, BytesRejection>,
) -> Result<Json<StreamSummary>, ApiError> {
    let bytes = payload
        .map_err(|error| ApiError::new(error.status(), "invalid_body", error.body_text()))?;
    let encodings: Vec<_> = headers.get_all(header::CONTENT_ENCODING).iter().collect();
    let gzip = match encodings.as_slice() {
        [] => false,
        [encoding]
            if encoding
                .to_str()
                .is_ok_and(|v| v.eq_ignore_ascii_case("identity")) =>
        {
            false
        }
        [encoding]
            if encoding
                .to_str()
                .is_ok_and(|v| v.eq_ignore_ascii_case("gzip")) =>
        {
            true
        }
        _ => {
            return Err(ApiError::new(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "unsupported_encoding",
                "Send scan chunks as JSON or gzip-compressed JSON.",
            ));
        }
    };
    if !headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            v.split(';')
                .next()
                .is_some_and(|v| v.trim().eq_ignore_ascii_case("application/json"))
        })
    {
        return Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "invalid_content_type",
            "Scan chunks require application/json.",
        ));
    }
    blocking(move || {
        let value = decode_chunk(&bytes, gzip)?;
        state.streams.append(&id, sequence, value)
    })
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
    headers: HeaderMap,
) -> Result<(HeaderMap, Vec<u8>), ApiError> {
    let response = reconstruct(state.clone(), id.clone(), false, accepts_gzip(&headers)).await?;
    package_in_background(state, id);
    Ok(response)
}

/// Stores a whole-capture attachment (RoomPlan export, semantics, OCR text, movement track).
pub async fn asset(
    State(state): State<AppState>,
    Path((id, name)): Path<(String, String)>,
    body: Result<Bytes, BytesRejection>,
) -> Result<StatusCode, ApiError> {
    let body = body.map_err(|error| ApiError::invalid(error.body_text()))?;
    blocking(move || state.streams.put_asset(&id, &name, &body)).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Once a stream has a reconstruction, package it as an ordinary immutable scan so the scan
/// store, Studio, building maps and the analysis worker can use it. Existing scans are
/// skipped; failures or busy processing slots are retried on the next result request.
fn package_in_background(state: AppState, id: String) {
    tokio::spawn(async move {
        if state.scans.get(&id).await.is_some() {
            return;
        }
        let Ok(permit) = state.processing_permit() else {
            return;
        };
        let streams = state.streams.clone();
        let stream_id = id.clone();
        let built = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let result = streams
                .reconstruct_encoded(&stream_id, false)
                .map_err(|error| format!("{error:?}"))?;
            let archive = crate::stream_scan::build_package(&streams, &stream_id, &result)
                .map_err(|error| format!("{error:?}"))?;
            let package = crate::scan_package::decode(&archive)?;
            Ok::<_, String>((package, archive))
        })
        .await;
        let (package, archive) = match built {
            Ok(Ok(built)) => built,
            Ok(Err(error)) => {
                tracing::warn!(stream = %id, ?error, "Could not package stream as a scan");
                return;
            }
            Err(error) => {
                tracing::error!(stream = %id, %error, "Stream packaging task failed");
                return;
            }
        };
        let scan = crate::store::StoredScan {
            original: package.original,
            bundle: package.bundle,
            package_assets: Some(package.assets),
            package_manifest: package.manifest,
        };
        match state.scans.insert(scan, Some(archive)).await {
            Ok(()) => {
                tracing::info!(stream = %id, "Packaged stream as a scan for the analysis pipeline")
            }
            Err(crate::store::ScanInsertError::Exists) => {}
            Err(error) => tracing::error!(stream = %id, ?error, "Could not store packaged stream"),
        }
    });
}

pub async fn scene(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<(HeaderMap, Vec<u8>), ApiError> {
    reconstruct(state, id, true, accepts_gzip(&headers)).await
}

async fn reconstruct(
    state: AppState,
    id: String,
    scene_only: bool,
    gzip: bool,
) -> Result<(HeaderMap, Vec<u8>), ApiError> {
    // Two builders plus two callers sharing those builds are enough for a local phone.
    // Acquire before spawn_blocking so slow jobs cannot accumulate unlimited waiters.
    let permit = state.processing_permit()?;
    blocking(move || {
        let _permit = permit;
        let bytes = state.streams.reconstruct_encoded(&id, scene_only)?;
        Ok(compress_response(bytes, gzip))
    })
    .await
    .map(|(compressed, bytes)| {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_TYPE, "application/json".parse().unwrap());
        headers.insert(header::VARY, "Accept-Encoding".parse().unwrap());
        if compressed {
            headers.insert(header::CONTENT_ENCODING, "gzip".parse().unwrap());
        }
        (headers, bytes)
    })
}

/// Explicit gzip refusal takes precedence over wildcard acceptance. Repeated refusal
/// also wins, so an ambiguous header never sends a representation the client rejected.
fn accepts_gzip(headers: &HeaderMap) -> bool {
    let mut explicit = None;
    let mut wildcard = None;
    for value in headers.get_all(header::ACCEPT_ENCODING).iter() {
        let Ok(value) = value.to_str() else { continue };
        for encoding in value.split(',') {
            let mut parameters = encoding.split(';');
            let name = parameters.next().unwrap_or_default().trim();
            let target = if name.eq_ignore_ascii_case("gzip") {
                &mut explicit
            } else if name == "*" {
                &mut wildcard
            } else {
                continue;
            };
            let allowed = parameters.all(|parameter| match parameter.split_once('=') {
                Some((name, quality)) if name.trim().eq_ignore_ascii_case("q") => quality
                    .trim()
                    .parse::<f64>()
                    .is_ok_and(|value| value > 0.0 && value <= 1.0),
                None if parameter.trim().eq_ignore_ascii_case("q") => false,
                _ => true,
            });
            *target = Some(target.unwrap_or(true) && allowed);
        }
    }
    explicit.or(wildcard).unwrap_or(false)
}

/// A result is already cached as immutable JSON. Compress off the async executor while
/// holding its response-worker slot, without changing that cache or allocating a larger
/// wire representation than the original. Clients without gzip keep ordinary JSON.
fn compress_response(bytes: Vec<u8>, gzip: bool) -> (bool, Vec<u8>) {
    if !gzip {
        return (false, bytes);
    }
    let output = SmallerWriter {
        bytes: Vec::new(),
        original_len: bytes.len(),
    };
    let mut encoder = flate2::write::GzEncoder::new(output, flate2::Compression::fast());
    if encoder.write_all(&bytes).is_err() {
        return (false, bytes);
    }
    match encoder.finish() {
        Ok(output) if output.bytes.len() < bytes.len() => (true, output.bytes),
        _ => (false, bytes),
    }
}

struct SmallerWriter {
    bytes: Vec<u8>,
    original_len: usize,
}
impl Write for SmallerWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if self.bytes.len().saturating_add(bytes.len()) >= self.original_len {
            return Err(std::io::Error::other(
                "gzip is not smaller than the original result",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn decode_chunk(bytes: &[u8], gzip: bool) -> Result<Value, StreamError> {
    if !gzip {
        return serde_json::from_slice(bytes)
            .map_err(|error| StreamError::Malformed(error.to_string()));
    }
    let mut decoder = flate2::bufread::GzDecoder::new(Cursor::new(bytes));
    let mut expanded = Vec::new();
    (&mut decoder)
        .take(MAX_CHUNK_BYTES as u64 + 1)
        .read_to_end(&mut expanded)
        .map_err(|_| {
            StreamError::Malformed("The gzip scan chunk is invalid or incomplete.".into())
        })?;
    if expanded.len() > MAX_CHUNK_BYTES {
        return Err(StreamError::Limit(
            "Each expanded chunk must be at most 4 MiB.".into(),
        ));
    }
    if decoder.into_inner().position() != bytes.len() as u64 {
        return Err(StreamError::Malformed(
            "The gzip scan chunk must contain one complete member without trailing data.".into(),
        ));
    }
    serde_json::from_slice(&expanded).map_err(|error| StreamError::Malformed(error.to_string()))
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
        StreamError::Malformed(message) => {
            ApiError::new(StatusCode::BAD_REQUEST, "invalid_json", message)
        }
        StreamError::Conflict(message) => {
            ApiError::new(StatusCode::CONFLICT, "stream_conflict", message)
        }
        StreamError::Limit(message) => {
            ApiError::new(StatusCode::PAYLOAD_TOO_LARGE, "stream_limit", message)
        }
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
        StreamError::Busy => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "processing_busy",
            "Two scans are already processing. Retry shortly.",
        ),
        StreamError::RecognitionPending => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "recognition_pending",
            "The scan is still identifying objects. Retry shortly.",
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::response::IntoResponse;

    #[tokio::test]
    async fn saturated_response_workers_return_retryable_busy_without_queueing() {
        let state = AppState::default();
        let id = "c626697c-855c-4f52-a574-9882e3593840";
        state
            .streams
            .create(serde_json::json!({"schema_version":1,"id":id,
            "map_id":"synthetic","floor_id":"ground",
            "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}}))
            .unwrap();
        let permits: Vec<_> = (0..4)
            .map(|_| {
                state
                    .processing_requests
                    .clone()
                    .try_acquire_owned()
                    .unwrap()
            })
            .collect();
        let busy = reconstruct(state.clone(), id.to_owned(), false, false)
            .await
            .unwrap_err()
            .into_response();
        assert_eq!(busy.status(), StatusCode::SERVICE_UNAVAILABLE);
        drop(permits);
        let available = reconstruct(state, id.to_owned(), false, false)
            .await
            .unwrap_err()
            .into_response();
        assert_eq!(available.status(), StatusCode::CONFLICT); // Admission resumes; source is unfinished.
    }
}
