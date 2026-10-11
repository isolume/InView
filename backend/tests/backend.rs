use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{
    AppState, app,
    graph::{Availability, ConnectorKind, Graph, Segment},
    routing::{self, RouteError, RouteRequest},
};
use serde_json::{Value, json};
use tower::ServiceExt;

fn graph() -> Graph {
    serde_json::from_str(include_str!("../examples/graph.json")).unwrap()
}

fn request() -> RouteRequest {
    serde_json::from_str(include_str!("../examples/route.json")).unwrap()
}

fn graph_with_ramp(ramp_seconds: f64) -> Graph {
    let mut value = serde_json::to_value(graph()).unwrap();
    value["nodes"].as_array_mut().unwrap().extend([
        json!({ "id": "ramp-ground", "map_id": "ground-scan", "floor_id": "ground",
                "x": 8, "y": 0, "z": 0 }),
        json!({ "id": "ramp-upper", "map_id": "upper-scan", "floor_id": "upper",
                "x": -4, "y": 0, "z": 0 }),
    ]);
    value["edges"].as_array_mut().unwrap().extend([
        json!({
            "id": "ramp-approach", "from": "entrance", "to": "ramp-ground",
            "step_free": true, "availability": "available",
            "minimum_clear_width_m": 1.2, "maximum_slope": 0,
            "segment": { "type": "surface", "map_id": "ground-scan", "floor_id": "ground",
                "path_points": [{ "x": 0, "y": 0, "z": 0 }, { "x": 8, "y": 0, "z": 0 }] }
        }),
        json!({
            "id": "ramp-a-crossing", "from": "ramp-ground", "to": "ramp-upper",
            "step_free": true, "availability": "available",
            "minimum_clear_width_m": 1.2, "maximum_slope": 0.05,
            "segment": { "type": "transition", "connector_id": "ramp-a", "kind": "ramp",
                "estimated_seconds": ramp_seconds }
        }),
        json!({
            "id": "ramp-exit", "from": "ramp-upper", "to": "room-204",
            "step_free": true, "availability": "available",
            "minimum_clear_width_m": 1.2, "maximum_slope": 0,
            "segment": { "type": "surface", "map_id": "upper-scan", "floor_id": "upper",
                "path_points": [{ "x": -4, "y": 0, "z": 0 }, { "x": 4, "y": 0, "z": 0 }] }
        }),
    ]);
    serde_json::from_value(value).unwrap()
}

#[test]
fn step_free_route_uses_elevator_and_keeps_scan_frames_separate() {
    let graph = graph();
    graph.validate().unwrap();
    let route = routing::find_route(&graph, &request()).unwrap();
    assert_eq!(
        route.node_ids,
        ["entrance", "elevator-ground", "elevator-upper", "room-204"]
    );
    assert_eq!(route.estimated_seconds, 34.0);
    let json = serde_json::to_value(route).unwrap();
    assert_eq!(json["segments"][0]["map_id"], "ground-scan");
    assert_eq!(json["segments"][1]["type"], "transition");
    assert_eq!(json["segments"][1]["from_floor_id"], "ground");
    assert_eq!(json["segments"][1]["to_floor_id"], "upper");
    assert!(json["segments"][1].get("path_points").is_none());
    assert_eq!(json["segments"][2]["map_id"], "upper-scan");
    assert_eq!(json["requirements"]["requires_step_free"], true);
}

#[test]
fn shortest_route_can_use_stairs_when_permitted() {
    let mut request = request();
    request.requirements = Default::default();
    let route = routing::find_route(&graph(), &request).unwrap();
    assert_eq!(route.node_ids, ["entrance", "room-204"]);
    assert_eq!(route.estimated_seconds, 12.0);
}

#[test]
fn fastest_route_uses_elevator_when_stairs_are_slower() {
    let mut graph = graph();
    if let Segment::Transition {
        estimated_seconds, ..
    } = &mut graph.edges[3].segment
    {
        *estimated_seconds = 50.0;
    }
    graph.validate().unwrap();
    let mut request = request();
    request.requirements = Default::default();
    let route = routing::find_route(&graph, &request).unwrap();
    assert_eq!(route.estimated_seconds, 34.0);
    assert_eq!(route.segments[1].edge_id, "elevator-a-ride");
    assert!(!route.requirements.requires_step_free);
}

#[test]
fn step_free_route_uses_suitable_ramp_and_preserves_separate_scan_frames() {
    let graph = graph_with_ramp(10.0);
    graph.validate().unwrap();
    let route = routing::find_route(&graph, &request()).unwrap();
    assert_eq!(route.estimated_seconds, 26.0);
    assert_eq!(
        route.node_ids,
        ["entrance", "ramp-ground", "ramp-upper", "room-204"]
    );
    let body = serde_json::to_value(route).unwrap();
    let crossing = &body["segments"][1];
    assert_eq!(crossing["type"], "transition");
    assert_eq!(crossing["kind"], "ramp");
    assert_eq!(crossing["connector_id"], "ramp-a");
    assert_eq!(crossing["from_map_id"], "ground-scan");
    assert_eq!(crossing["to_map_id"], "upper-scan");
    assert_eq!(crossing["from_floor_id"], "ground");
    assert_eq!(crossing["to_floor_id"], "upper");
    assert!(crossing.get("path_points").is_none());
    assert_eq!(body["segments"][0]["path_points"][1]["x"], 8.0);
    assert_eq!(body["segments"][2]["path_points"][0]["x"], -4.0);
    assert_eq!(body["requirements"]["maximum_slope"], 0.08);
}

#[test]
fn step_free_selection_compares_total_ramp_and_elevator_journey_times() {
    // The ramp crossing itself is faster than the 25-second elevator ride, but its
    // longer approach and exit make the full trip 36 seconds instead of 34.
    let graph = graph_with_ramp(20.0);
    graph.validate().unwrap();
    let route = routing::find_route(&graph, &request()).unwrap();
    assert_eq!(route.estimated_seconds, 34.0);
    assert_eq!(route.segments[1].edge_id, "elevator-a-ride");
}

#[test]
fn unknown_narrow_or_steep_ramp_uses_elevator_without_stairs_fallback() {
    for (step_free, width, slope) in [
        (None, Some(1.2), Some(0.05)),
        (Some(false), Some(1.2), Some(0.05)),
        (Some(true), None, Some(0.05)),
        (Some(true), Some(0.8), Some(0.05)),
        (Some(true), Some(1.2), None),
        (Some(true), Some(1.2), Some(0.1)),
    ] {
        let mut graph = graph_with_ramp(10.0);
        let ramp = graph
            .edges
            .iter_mut()
            .find(|edge| edge.id == "ramp-a-crossing")
            .unwrap();
        ramp.step_free = step_free;
        ramp.minimum_clear_width_m = width;
        ramp.maximum_slope = slope;
        graph.validate().unwrap();
        let route = routing::find_route(&graph, &request()).unwrap();
        assert_eq!(route.segments[1].edge_id, "elevator-a-ride");
        graph.edges[1].availability = Availability::Closed;
        assert_eq!(
            routing::find_route(&graph, &request()).unwrap_err(),
            RouteError::NoVerifiedRoute
        );
    }
}

#[test]
fn closed_or_unknown_ramp_is_excluded_and_never_relaxes_step_free_requirements() {
    for availability in [Availability::Closed, Availability::Unknown] {
        let mut graph = graph_with_ramp(10.0);
        graph
            .edges
            .iter_mut()
            .find(|edge| edge.id == "ramp-a-crossing")
            .unwrap()
            .availability = availability;
        let route = routing::find_route(&graph, &request()).unwrap();
        assert_eq!(route.segments[1].edge_id, "elevator-a-ride");
        graph.edges[1].availability = availability;
        assert_eq!(
            routing::find_route(&graph, &request()).unwrap_err(),
            RouteError::NoVerifiedRoute
        );
        let mut fastest = request();
        fastest.requirements = Default::default();
        assert_eq!(
            routing::find_route(&graph, &fastest).unwrap().node_ids,
            ["entrance", "room-204"]
        );
        graph.edges[3].availability = Availability::Closed;
        assert_eq!(
            routing::find_route(&graph, &fastest).unwrap_err(),
            RouteError::NoVerifiedRoute
        );
    }
}

#[test]
fn closed_or_unknown_elevator_never_falls_back_to_stairs() {
    for availability in [Availability::Closed, Availability::Unknown] {
        let mut graph = graph();
        graph.edges[1].availability = availability;
        assert_eq!(
            routing::find_route(&graph, &request()).unwrap_err(),
            RouteError::NoVerifiedRoute
        );
    }
}

#[test]
fn unknown_or_inadequate_measurements_cannot_meet_requirements() {
    for (step_free, width, slope) in [
        (None, Some(1.0), Some(0.0)),
        (Some(true), None, Some(0.0)),
        (Some(true), Some(0.8), Some(0.0)),
        (Some(true), Some(1.0), None),
        (Some(true), Some(1.0), Some(0.1)),
    ] {
        let mut graph = graph();
        graph.edges[1].step_free = step_free;
        graph.edges[1].minimum_clear_width_m = width;
        graph.edges[1].maximum_slope = slope;
        assert_eq!(
            routing::find_route(&graph, &request()).unwrap_err(),
            RouteError::NoVerifiedRoute
        );
    }
}

#[test]
fn movement_speed_changes_surface_time_only() {
    let mut request = request();
    request.movement_speed_mps = 0.5;
    assert_eq!(
        routing::find_route(&graph(), &request)
            .unwrap()
            .estimated_seconds,
        43.0
    );
}

#[test]
fn an_overflowing_branch_does_not_hide_a_finite_route() {
    let mut request = request();
    request.requirements = Default::default();
    request.movement_speed_mps = 1e-320;
    request.validate().unwrap();
    let route = routing::find_route(&graph(), &request).unwrap();
    assert_eq!(route.node_ids, ["entrance", "room-204"]);
    assert_eq!(route.estimated_seconds, 12.0);
    request.requirements.requires_step_free = true;
    assert_eq!(
        routing::find_route(&graph(), &request).unwrap_err(),
        RouteError::InvalidCost
    );
}

#[test]
fn searches_full_trip_instead_of_choosing_nearest_elevator() {
    let mut graph = graph();
    let mut landing = graph.nodes[1].clone();
    landing.id = "nearby-elevator".into();
    landing.x = 1.0;
    graph.nodes.push(landing);
    let mut edge = graph.edges[0].clone();
    edge.id = "nearby-dead-end".into();
    edge.to = "nearby-elevator".into();
    if let Segment::Surface { path_points, .. } = &mut edge.segment {
        path_points[1].x = 1.0;
    }
    graph.edges.push(edge);
    graph.validate().unwrap();
    let route = routing::find_route(&graph, &request()).unwrap();
    assert_eq!(route.segments[1].edge_id, "elevator-a-ride");
}

#[test]
fn edges_are_directed_and_same_node_needs_no_travel() {
    let mut request = request();
    request.from = "room-204".into();
    request.to = "entrance".into();
    assert_eq!(
        routing::find_route(&graph(), &request).unwrap_err(),
        RouteError::NoVerifiedRoute
    );
    request.to = request.from.clone();
    let route = routing::find_route(&graph(), &request).unwrap();
    assert!(route.segments.is_empty());
    assert_eq!(route.estimated_seconds, 0.0);
}

#[test]
fn validates_graph_references_and_geometry() {
    let mut invalid = graph();
    invalid.nodes.push(invalid.nodes[0].clone());
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    invalid.edges[0].to = "missing".into();
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    if let Segment::Surface { map_id, .. } = &mut invalid.edges[0].segment {
        *map_id = "upper-scan".into();
    }
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    if let Segment::Surface { path_points, .. } = &mut invalid.edges[0].segment {
        path_points[0].x = 2.0;
    }
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    invalid.edges[3].step_free = Some(true);
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    if let Segment::Transition {
        estimated_seconds, ..
    } = &mut invalid.edges[1].segment
    {
        *estimated_seconds = -1.0;
    }
    assert!(invalid.validate().is_err());
    let mut invalid = graph();
    invalid.nodes[0].x = f64::NAN;
    assert!(invalid.validate().is_err());
}

#[test]
fn preserves_ramp_heights_and_uses_full_3d_length() {
    let mut graph = graph();
    graph.nodes[1].y = 1.0;
    if let Segment::Surface { path_points, .. } = &mut graph.edges[0].segment {
        path_points[1].y = 1.0;
    }
    graph.edges[0].maximum_slope = Some(0.2);
    let mut request = request();
    request.requirements.maximum_slope = None;
    graph.validate().unwrap();
    let route = routing::find_route(&graph, &request).unwrap();
    assert!((route.estimated_seconds - (26.0_f64.sqrt() + 29.0)).abs() < 1e-10);
    if let Segment::Surface { path_points, .. } = &route.segments[0].geometry {
        assert_eq!(path_points[1].y, 1.0);
    } else {
        panic!("expected surface");
    }
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    payload: Option<Value>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(
            payload.map(|value| value.to_string()).unwrap_or_default(),
        ))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn api_stores_reloads_lists_and_routes_a_graph() {
    let app = app(AppState::default());
    assert_eq!(call(&app, "GET", "/health", None).await.0, StatusCode::OK);
    assert_eq!(call(&app, "GET", "/graphs", None).await.1, json!([]));
    let payload = serde_json::to_value(graph()).unwrap();
    let (status, summary) = call(&app, "PUT", "/graphs/demo-building", Some(payload.clone())).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(summary["node_count"], 4);
    assert_eq!(
        call(&app, "GET", "/graphs/demo-building", None).await.1,
        payload
    );
    assert_eq!(
        call(&app, "GET", "/graphs", None).await.1[0]["id"],
        "demo-building"
    );
    let route = serde_json::from_str(include_str!("../examples/route.json")).unwrap();
    let (status, body) = call(&app, "POST", "/graphs/demo-building/routes", Some(route)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["estimated_seconds"].as_f64(), Some(34.0));
    // A new service instance starts empty; storage is intentionally process-local.
    assert_eq!(
        call(&app_with_empty_state(), "GET", "/graphs", None)
            .await
            .1,
        json!([])
    );
}

fn app_with_empty_state() -> Router {
    app(AppState::default())
}

#[tokio::test]
async fn invalid_replacement_does_not_overwrite_existing_graph() {
    let app = app(AppState::default());
    let original = serde_json::to_value(graph()).unwrap();
    call(&app, "PUT", "/graphs/demo-building", Some(original.clone())).await;
    let mut invalid = original.clone();
    invalid["edges"][0]["to"] = json!("missing");
    let (status, body) = call(&app, "PUT", "/graphs/demo-building", Some(invalid)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "invalid_input");
    assert_eq!(
        call(&app, "GET", "/graphs/demo-building", None).await.1,
        original
    );
}

#[tokio::test]
async fn api_returns_structured_errors_and_rejects_misspelled_requirements() {
    let app = app(AppState::default());
    let (status, body) = call(&app, "GET", "/graphs/missing", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "graph_not_found");
    let (status, body) = call(
        &app,
        "POST",
        "/graphs/missing/routes",
        Some(json!({
            "from": "entrance", "to": "room-204", "requirements": { "require_step_free": true }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "invalid_json");
    assert_eq!(
        call(
            &app,
            "PUT",
            "/graphs/wrong-id",
            Some(serde_json::to_value(graph()).unwrap())
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        call(&app, "GET", "/missing", None).await.1["error"]["code"],
        "not_found"
    );
    assert_eq!(
        call(&app, "POST", "/health", None).await.0,
        StatusCode::METHOD_NOT_ALLOWED
    );
}

#[tokio::test]
async fn api_reports_no_verified_route_and_validates_speed() {
    let app = app(AppState::default());
    let mut graph = graph();
    graph.edges[1].availability = Availability::Closed;
    call(
        &app,
        "PUT",
        "/graphs/demo-building",
        Some(serde_json::to_value(graph).unwrap()),
    )
    .await;
    let mut request: Value = serde_json::from_str(include_str!("../examples/route.json")).unwrap();
    let (status, body) = call(
        &app,
        "POST",
        "/graphs/demo-building/routes",
        Some(request.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "no_verified_route");
    request["movement_speed_mps"] = json!(0);
    assert_eq!(
        call(&app, "POST", "/graphs/demo-building/routes", Some(request))
            .await
            .1["error"]["code"],
        "invalid_input"
    );
}

#[tokio::test]
async fn api_switches_fastest_and_step_free_requests_without_retaining_old_requirements() {
    let app = app(AppState::default());
    let mut graph = graph_with_ramp(10.0);
    assert_eq!(
        call(
            &app,
            "PUT",
            "/graphs/demo-building",
            Some(serde_json::to_value(&graph).unwrap())
        )
        .await
        .0,
        StatusCode::OK
    );
    let step_free: Value = serde_json::from_str(include_str!("../examples/route.json")).unwrap();
    let mut gentler = step_free.clone();
    gentler["requirements"]["maximum_slope"] = json!(0.04);
    let fastest = json!({
        "from": "entrance", "to": "room-204",
        "requirements": { "requires_step_free": false }
    });
    for (payload, connector, seconds) in [
        (step_free.clone(), "ramp", 26.0),
        (gentler, "elevator", 34.0),
        (fastest.clone(), "stairs", 12.0),
        (step_free.clone(), "ramp", 26.0),
    ] {
        let (status, body) = call(
            &app,
            "POST",
            "/graphs/demo-building/routes",
            Some(payload.clone()),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["estimated_seconds"], seconds);
        let transition = body["segments"]
            .as_array()
            .unwrap()
            .iter()
            .find(|segment| segment["type"] == "transition")
            .unwrap();
        assert_eq!(transition["kind"], connector);
        assert_eq!(
            body["requirements"]["requires_step_free"],
            payload["requirements"]["requires_step_free"]
        );
        assert_eq!(
            body["requirements"]["minimum_clear_width_m"],
            payload["requirements"]["minimum_clear_width_m"]
        );
        assert_eq!(
            body["requirements"]["maximum_slope"],
            payload["requirements"]["maximum_slope"]
        );
    }

    for edge in &mut graph.edges {
        if matches!(
            edge.segment,
            Segment::Transition {
                kind: ConnectorKind::Elevator | ConnectorKind::Ramp,
                ..
            }
        ) {
            edge.availability = Availability::Closed;
        }
    }
    assert_eq!(
        call(
            &app,
            "PUT",
            "/graphs/demo-building",
            Some(serde_json::to_value(graph).unwrap())
        )
        .await
        .0,
        StatusCode::OK
    );
    let (status, body) = call(
        &app,
        "POST",
        "/graphs/demo-building/routes",
        Some(step_free),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "no_verified_route");
    let (status, body) = call(&app, "POST", "/graphs/demo-building/routes", Some(fastest)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["segments"][0]["kind"], "stairs");
    assert_eq!(body["requirements"]["requires_step_free"], false);
}
