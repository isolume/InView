//! The worker's key-aspect highlights for a scan: ranked findings and the annotated plan image.
use axum::{
    Json,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{AppState, error::ApiError};

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HighlightQuery {
    /// Comma-separated: barrier, narrow_passage, door, access_feature, wayfinding, route.
    kinds: Option<String>,
    /// Comma-separated: barrier, warning, asset, info.
    severity: Option<String>,
    min_importance: Option<f64>,
    limit: Option<usize>,
    /// Include the base64 PNG in the JSON (large); `/highlights.png` serves it directly.
    image: Option<bool>,
}

fn not_processed() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "analysis_not_found",
        "This scan has not been processed by the analysis worker yet.",
    )
}

fn no_highlights() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "highlights_not_found",
        "Highlights have not been generated for this scan. Process it again with the current worker.",
    )
}

fn words(value: &Option<String>) -> Result<Option<Vec<String>>, ApiError> {
    let Some(raw) = value else { return Ok(None) };
    let parts: Vec<String> = raw
        .split(',')
        .map(|p| p.trim().to_ascii_lowercase())
        .filter(|p| !p.is_empty())
        .collect();
    let valid = parts.len() <= 12
        && parts
            .iter()
            .all(|p| p.len() <= 32 && p.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'));
    if parts.is_empty() || !valid {
        return Err(ApiError::invalid(
            "Use comma-separated lowercase names, such as kinds=door,barrier.",
        ));
    }
    Ok(Some(parts))
}

async fn highlights_of(state: &AppState, scan_id: &str) -> Result<Value, ApiError> {
    state.scans.get(scan_id).await.ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "scan_not_found",
            "This scan is not available.",
        )
    })?;
    let analysis = state
        .scans
        .analysis(scan_id)
        .await
        .ok_or_else(not_processed)?;
    analysis
        .get("highlights")
        .filter(|h| h.is_object())
        .cloned()
        .ok_or_else(no_highlights)
}

/// `GET /scans/{id}/highlights`: ranked findings, optionally filtered. The numbers in the image
/// are the unfiltered ranks, so filtering never renumbers what the picture shows.
pub async fn get(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
    Query(query): Query<HighlightQuery>,
) -> Result<Json<Value>, ApiError> {
    let kinds = words(&query.kinds)?;
    let severities = words(&query.severity)?;
    if query
        .min_importance
        .is_some_and(|m| !m.is_finite() || !(0.0..=1.0).contains(&m))
    {
        return Err(ApiError::invalid("min_importance must be within 0–1."));
    }
    if query.limit.is_some_and(|l| !(1..=100).contains(&l)) {
        return Err(ApiError::invalid("limit must be within 1–100."));
    }
    let mut highlights = highlights_of(&state, &scan_id).await?;
    let total = highlights["items"].as_array().map_or(0, Vec::len);
    let text = |item: &Value, key: &str| {
        item.get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    let kept: Vec<Value> = highlights["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| kinds.as_ref().is_none_or(|k| k.contains(&text(i, "kind"))))
        .filter(|i| {
            severities
                .as_ref()
                .is_none_or(|s| s.contains(&text(i, "severity")))
        })
        .filter(|i| {
            query
                .min_importance
                .is_none_or(|m| i.get("importance").and_then(Value::as_f64).unwrap_or(0.0) >= m)
        })
        .take(query.limit.unwrap_or(100))
        .collect();
    highlights["matched"] = json!(kept.len());
    highlights["total"] = json!(total);
    highlights["items"] = Value::Array(kept);
    highlights["scan_id"] = json!(scan_id);
    highlights["image_url"] = json!(format!("/scans/{scan_id}/highlights.png"));
    if !query.image.unwrap_or(false)
        && let Some(image) = highlights.get_mut("image").and_then(Value::as_object_mut)
    {
        image.remove("png_base64");
    }
    Ok(Json(highlights))
}

/// `GET /scans/{id}/highlights.png`: the annotated plan as an image.
pub async fn image(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
) -> Result<Response, ApiError> {
    let highlights = highlights_of(&state, &scan_id).await?;
    let encoded = highlights
        .pointer("/image/png_base64")
        .and_then(Value::as_str)
        .ok_or_else(no_highlights)?;
    let bytes = STANDARD.decode(encoded).map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "highlights_image_invalid",
            "The stored highlights image could not be read.",
        )
    })?;
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "highlights_image_invalid",
            "The stored highlights image could not be read.",
        ));
    }
    Ok((
        [
            (header::CONTENT_TYPE, "image/png"),
            (header::CACHE_CONTROL, "no-store"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        bytes,
    )
        .into_response())
}
