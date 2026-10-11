use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::Arc;

use crate::{
    AppState,
    error::ApiError,
    graph::{Graph, GraphSummary},
    routing::{self, Route, RouteError, RouteRequest},
};

pub async fn health() -> Json<Value> {
    Json(json!({ "status": "ok", "service": "inview-backend" }))
}

pub async fn list_graphs(State(state): State<AppState>) -> Json<Vec<GraphSummary>> {
    Json(state.graphs.list().await)
}

pub async fn get_graph(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Graph>, ApiError> {
    let graph = readable_graph(&state, &id, &headers).await?;
    let mut graph = (*graph).clone();
    if !crate::auth::processing_access(state.api_token.as_deref(), &headers)
        && let Some(publication) = graph
            .metadata
            .get_mut("publication")
            .and_then(Value::as_object_mut)
    {
        publication.remove("reviewed_by");
    }
    Ok(Json(graph))
}

async fn readable_graph(
    state: &AppState,
    id: &str,
    headers: &HeaderMap,
) -> Result<Arc<Graph>, ApiError> {
    if crate::auth::processing_access(state.api_token.as_deref(), headers) {
        state
            .graphs
            .get(id)
            .await
            .or(state.published_graphs.get(id).await)
    } else {
        state.published_graphs.get(id).await
    }
    .ok_or_else(ApiError::missing_graph)
}

/// Stable identifier for exactly the candidate an administrator reviewed.
pub fn graph_fingerprint(graph: &Graph) -> String {
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(graph).expect("validated graph JSON"))
    )
}

pub async fn review_graph(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    crate::product_api::admin(&state, &headers)?;
    let graph = state
        .graphs
        .get(&id)
        .await
        .ok_or_else(ApiError::missing_graph)?;
    Ok(Json(
        json!({"fingerprint": graph_fingerprint(&graph), "graph": &*graph}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublishGraphRequest {
    pub expected_fingerprint: String,
    pub geometry_reviewed: bool,
    pub routes_reviewed: bool,
    pub floor_links_reviewed: bool,
}

/// Publish an explicit snapshot. Processing credentials alone can never perform this action.
pub async fn publish_graph(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    payload: Result<Json<PublishGraphRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let reviewer = crate::product_api::admin(&state, &headers)?;
    let Json(request) = payload.map_err(json_error)?;
    if !request.geometry_reviewed || !request.routes_reviewed || !request.floor_links_reviewed {
        return Err(ApiError::invalid(
            "Review the map, routes and floor connections before publishing.",
        ));
    }
    let graph = state
        .graphs
        .get(&id)
        .await
        .ok_or_else(ApiError::missing_graph)?;
    let fingerprint = graph_fingerprint(&graph);
    if fingerprint != request.expected_fingerprint {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "revision_conflict",
            "The graph changed. Review the latest graph before publishing.",
        ));
    }
    if graph.metadata.get("venue_id").and_then(Value::as_str) != Some(id.as_str()) {
        return Err(ApiError::invalid(
            "Publish a building graph with a matching venue identity.",
        ));
    }
    if let Some(published) = state.published_graphs.get(&id).await
        && published
            .metadata
            .get("publication")
            .and_then(|p| p.get("source_fingerprint"))
            .and_then(Value::as_str)
            == Some(&fingerprint)
    {
        return Ok(Json(
            json!({"id": id, "source_fingerprint": fingerprint, "published": true}),
        ));
    }
    let mut published = (*graph).clone();
    published
        .metadata
        .insert("review_status".into(), json!("reviewed"));
    published.metadata.insert(
        "publication".into(),
        json!({
            "status": "reviewed", "source_fingerprint": fingerprint,
            "reviewed_by": reviewer.id, "published_at": crate::product_store::now(),
        }),
    );
    state
        .published_graphs
        .publish(published)
        .await
        .map_err(|error| {
            tracing::error!(%error, "Could not persist reviewed graph");
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "graph_storage_error",
                "The reviewed graph could not be saved.",
            )
        })?;
    Ok(Json(
        json!({"id": id, "source_fingerprint": fingerprint, "published": true}),
    ))
}

pub async fn put_graph(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<Graph>, JsonRejection>,
) -> Result<Json<GraphSummary>, ApiError> {
    let Json(graph) = payload.map_err(json_error)?;
    if graph.id != id {
        return Err(ApiError::invalid("The graph id must match the URL."));
    }
    graph.validate().map_err(ApiError::invalid)?;
    let summary = graph.summary();
    state.graphs.put(graph).await.map_err(|error| {
        tracing::error!(%error, "Could not persist graph");
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "graph_storage_error",
            "The graph could not be saved.",
        )
    })?;
    Ok(Json(summary))
}

pub async fn route(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    payload: Result<Json<RouteRequest>, JsonRejection>,
) -> Result<Json<Route>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    request.validate().map_err(ApiError::invalid)?;
    let graph = readable_graph(&state, &id, &headers).await?;
    routing::find_route(&graph, &request)
        .map(Json)
        .map_err(|error| match error {
            RouteError::UnknownNode => {
                ApiError::invalid("Start and destination must be nodes in this graph.")
            }
            RouteError::NoVerifiedRoute => ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "no_verified_route",
                "No verified route meets the requested requirements.",
            ),
            RouteError::InvalidCost => {
                ApiError::invalid("These values produce an invalid travel time.")
            }
        })
}

fn json_error(error: JsonRejection) -> ApiError {
    ApiError::new(error.status(), "invalid_json", error.body_text())
}

pub async fn not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_found",
        "This endpoint does not exist.",
    )
}

pub async fn method_not_allowed() -> ApiError {
    ApiError::new(
        StatusCode::METHOD_NOT_ALLOWED,
        "method_not_allowed",
        "This method is not supported.",
    )
}
