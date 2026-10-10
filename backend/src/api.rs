use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::StatusCode,
};
use serde_json::{Value, json};

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
) -> Result<Json<Graph>, ApiError> {
    state
        .graphs
        .get(&id)
        .await
        .map(|graph| Json((*graph).clone()))
        .ok_or_else(ApiError::missing_graph)
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
    payload: Result<Json<RouteRequest>, JsonRejection>,
) -> Result<Json<Route>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    request.validate().map_err(ApiError::invalid)?;
    let graph = state
        .graphs
        .get(&id)
        .await
        .ok_or_else(ApiError::missing_graph)?;
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
