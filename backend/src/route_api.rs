//! Multi-level, multi-path routes between two points of a scan or an aligned building.
use std::sync::{Arc, Mutex};

use axum::{
    Json,
    extract::{Path, Query, State, rejection::JsonRejection},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    AppState,
    building_nav::{
        NavModel,
        compose::{self, ManualConnector, ScanLayer},
        nearby::{self, NearbyRequest},
        plan::{self, PlanError, RouteRequest},
    },
    buildings,
    error::ApiError,
    graph::Graph,
    map_frame,
};

/// Recently composed models; entries are reused only while their inputs are the same objects.
const CACHE_ENTRIES: usize = 8;

struct CacheEntry {
    scope: String,
    graphs: Vec<Arc<Graph>>,
    analyses: Vec<Option<Arc<Value>>>,
    manual: Vec<ManualConnector>,
    model: Arc<NavModel>,
}

static CACHE: Mutex<Vec<CacheEntry>> = Mutex::new(Vec::new());

fn cached(scope: &str, layers: &[ScanLayer], manual: &[ManualConnector]) -> Option<Arc<NavModel>> {
    let cache = CACHE.lock().ok()?;
    let manual_json = serde_json::to_string(manual).ok()?;
    cache
        .iter()
        .find(|entry| {
            entry.scope == scope
                && entry.graphs.len() == layers.len()
                && entry
                    .graphs
                    .iter()
                    .zip(layers)
                    .all(|(g, l)| Arc::ptr_eq(g, &l.graph))
                && entry
                    .analyses
                    .iter()
                    .zip(layers)
                    .all(|(a, l)| match (a, &l.analysis) {
                        (Some(a), Some(b)) => Arc::ptr_eq(a, b),
                        (None, None) => true,
                        _ => false,
                    })
                && serde_json::to_string(&entry.manual).ok().as_deref()
                    == Some(manual_json.as_str())
        })
        .map(|entry| entry.model.clone())
}

fn remember(
    scope: String,
    layers: &[ScanLayer],
    manual: Vec<ManualConnector>,
    model: Arc<NavModel>,
) {
    let Ok(mut cache) = CACHE.lock() else { return };
    cache.retain(|entry| entry.scope != scope);
    if cache.len() >= CACHE_ENTRIES {
        cache.remove(0);
    }
    cache.push(CacheEntry {
        scope,
        graphs: layers.iter().map(|l| l.graph.clone()).collect(),
        analyses: layers.iter().map(|l| l.analysis.clone()).collect(),
        manual,
        model,
    });
}

fn navigation_missing(message: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, "navigation_data_missing", message)
}

/// The scan's navigation graph: the reviewed snapshot if one is published, else processing output.
async fn layer(
    state: &AppState,
    scan_id: &str,
    transform: crate::geometry::Transform,
) -> Option<(ScanLayer, bool)> {
    let id = format!("{scan_id}-nav");
    let (graph, reviewed) = match state.published_graphs.get(&id).await {
        Some(graph) => (graph, true),
        None => (state.graphs.get(&id).await?, false),
    };
    let analysis = state.scans.analysis(scan_id).await;
    Some((
        ScanLayer {
            scan_id: scan_id.to_owned(),
            transform,
            graph,
            analysis,
        },
        reviewed,
    ))
}

async fn model(
    scope: String,
    layers: Vec<ScanLayer>,
    manual: Vec<ManualConnector>,
) -> Result<Arc<NavModel>, ApiError> {
    if let Some(model) = cached(&scope, &layers, &manual) {
        return Ok(model);
    }
    let (layers, manual, model) = tokio::task::spawn_blocking(move || {
        let model = Arc::new(compose::compose(&layers, &manual));
        (layers, manual, model)
    })
    .await
    .map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "composition_failed",
            "Could not compose the navigation map.",
        )
    })?;
    remember(scope, &layers, manual, model.clone());
    Ok(model)
}

async fn scan_model(
    state: &AppState,
    scan_id: &str,
) -> Result<(Arc<NavModel>, Vec<String>), ApiError> {
    let Some((layer, reviewed)) = layer(state, scan_id, map_frame::IDENTITY).await else {
        return Err(navigation_missing(
            "This scan has no navigation graph yet. Process it first.",
        ));
    };
    let mut notices = Vec::new();
    if !reviewed {
        notices.push("This scan's navigation graph has not been reviewed.".to_owned());
    }
    let model = model(format!("scan:{scan_id}"), vec![layer], vec![]).await?;
    Ok((model, notices))
}

async fn building_model(
    state: &AppState,
    id: &str,
    version: Option<i32>,
) -> Result<(Arc<NavModel>, Value, Vec<String>), ApiError> {
    let pool = state.maps.as_ref().ok_or_else(buildings::unavailable)?;
    let building = buildings::snapshot(pool, id, version).await?;
    let manual = buildings::manual_connectors(pool, building.id()).await?;
    let mut placements = building.placements();
    // The reference scan defines the building frame, so its geographic reference applies.
    placements.sort_by_key(|(capture, _)| capture != building.reference_capture_id());
    let mut layers = Vec::new();
    let mut notices = Vec::new();
    let mut unreviewed = 0;
    for (capture, transform) in placements {
        match layer(state, &capture, transform).await {
            Some((layer, reviewed)) => {
                unreviewed += usize::from(!reviewed);
                layers.push(layer);
            }
            None => notices.push(format!(
                "Scan {capture} has no navigation graph yet and was left out."
            )),
        }
    }
    if layers.is_empty() {
        return Err(navigation_missing(
            "No scan in this building has a navigation graph yet. Process its scans first.",
        ));
    }
    if unreviewed > 0 {
        notices.push(format!(
            "{unreviewed} of {} scan graphs have not been reviewed.",
            layers.len()
        ));
    }
    let scope = json!({"building_id": building.id(), "version": building.version()});
    let model = model(
        format!("building:{}:{}", building.id(), building.version()),
        layers,
        manual,
    )
    .await?;
    Ok((model, scope, notices))
}

fn plan_error(error: PlanError) -> ApiError {
    match error {
        PlanError::Invalid(message) => ApiError::invalid(message),
        PlanError::EndpointNotFound(which) => ApiError::new(
            StatusCode::NOT_FOUND,
            "endpoint_not_found",
            format!(
                "The '{which}' endpoint does not match a place, node, or walkable spot within {} m on its level.",
                plan::SNAP_MAX_M
            ),
        ),
        PlanError::NoRoute => ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "no_route",
            "No route connects these points in the captured map.",
        ),
    }
}

fn respond(
    model: &NavModel,
    request: &RouteRequest,
    scope: Value,
    mut notices: Vec<String>,
) -> Result<Json<Value>, ApiError> {
    let response = plan::plan(model, request).map_err(plan_error)?;
    let mut body = serde_json::to_value(&response).map_err(|e| ApiError::invalid(e.to_string()))?;
    notices.extend(response.notices);
    body["notices"] = json!(notices);
    body["scope"] = scope;
    body["frame"] = buildings::frame();
    Ok(Json(body))
}

fn parse(payload: Result<Json<RouteRequest>, JsonRejection>) -> Result<RouteRequest, ApiError> {
    let Json(request) =
        payload.map_err(|e| ApiError::new(e.status(), "invalid_json", e.body_text()))?;
    request.validate().map_err(ApiError::invalid)?;
    Ok(request)
}

pub async fn scan_routes(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
    payload: Result<Json<RouteRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let request = parse(payload)?;
    if request.version.is_some() {
        return Err(ApiError::invalid(
            "version applies to building routes only.",
        ));
    }
    let (model, notices) = scan_model(&state, &scan_id).await?;
    respond(&model, &request, json!({"scan_id": scan_id}), notices)
}

pub async fn building_routes(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<RouteRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let request = parse(payload)?;
    let (model, scope, notices) = building_model(&state, &id, request.version).await?;
    respond(&model, &request, scope, notices)
}

fn parse_nearby(
    payload: Result<Json<NearbyRequest>, JsonRejection>,
) -> Result<NearbyRequest, ApiError> {
    let Json(request) =
        payload.map_err(|e| ApiError::new(e.status(), "invalid_json", e.body_text()))?;
    request.validate().map_err(ApiError::invalid)?;
    Ok(request)
}

fn nearby_body(
    model: &NavModel,
    request: &NearbyRequest,
    scope: Value,
    mut notices: Vec<String>,
) -> Result<Json<Value>, ApiError> {
    let response = nearby::nearby(model, request).map_err(plan_error)?;
    let mut body = serde_json::to_value(&response).map_err(|e| ApiError::invalid(e.to_string()))?;
    notices.extend(response.notices);
    body["notices"] = json!(notices);
    body["scope"] = scope;
    body["frame"] = buildings::frame();
    Ok(Json(body))
}

/// Places, signs and connectors around a point of one processed scan.
pub async fn scan_nearby(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
    payload: Result<Json<NearbyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let request = parse_nearby(payload)?;
    if request.version.is_some() {
        return Err(ApiError::invalid(
            "version applies to building searches only.",
        ));
    }
    let (model, notices) = scan_model(&state, &scan_id).await?;
    nearby_body(&model, &request, json!({"scan_id": scan_id}), notices)
}

/// Places, signs and connectors around a point anywhere in an aligned building.
pub async fn building_nearby(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<NearbyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let request = parse_nearby(payload)?;
    let (model, scope, notices) = building_model(&state, &id, request.version).await?;
    nearby_body(&model, &request, scope, notices)
}

#[derive(Debug, Default, Deserialize)]
pub struct LevelsQuery {
    version: Option<i32>,
}

pub async fn scan_levels(
    State(state): State<AppState>,
    Path(scan_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let (model, notices) = scan_model(&state, &scan_id).await?;
    let mut body = plan::levels_summary(&model);
    body["scope"] = json!({"scan_id": scan_id});
    extend_notices(&mut body, notices);
    Ok(Json(body))
}

pub async fn building_levels(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<LevelsQuery>,
) -> Result<Json<Value>, ApiError> {
    let (model, scope, notices) = building_model(&state, &id, query.version).await?;
    let mut body = plan::levels_summary(&model);
    body["scope"] = scope;
    extend_notices(&mut body, notices);
    Ok(Json(body))
}

fn extend_notices(body: &mut Value, extra: Vec<String>) {
    let mut notices: Vec<Value> = extra.into_iter().map(Value::from).collect();
    notices.extend(body["notices"].as_array().cloned().unwrap_or_default());
    body["notices"] = Value::Array(notices);
}
