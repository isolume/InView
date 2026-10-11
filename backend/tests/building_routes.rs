use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{AppState, app, buildings, graph::Graph};
use serde_json::{Value, json};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

async fn send(
    router: &Router,
    method: &str,
    uri: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(
            body.map_or_else(Vec::new, |v| serde_json::to_vec(&v).unwrap()),
        ))
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

/// Two floors 3.5 m apart. Stairs join the east ends; elevators the west ends.
///   L1:  d(0) ——— e(5) ——— f(10)
///   L0:  a(0) ——— b(5) ——— c(10)    (b is a door)
fn two_floor_graph(scan: &str) -> Graph {
    let nodes = [
        ("a", "L0", 0.0, 0.0),
        ("b", "L0", 5.0, 0.0),
        ("c", "L0", 10.0, 0.0),
        ("d", "L1", 0.0, 3.5),
        ("e", "L1", 5.0, 3.5),
        ("f", "L1", 10.0, 3.5),
    ];
    let position = |id: &str| {
        nodes
            .iter()
            .find(|n| n.0 == id)
            .map(|n| (n.1, n.2, n.3))
            .unwrap()
    };
    let mut edges = Vec::new();
    let mut details = serde_json::Map::new();
    for (n, (from, to)) in [("a", "b"), ("b", "c"), ("d", "e"), ("e", "f")]
        .into_iter()
        .enumerate()
    {
        let base = format!("e{:04}", n + 1);
        let (floor, x0, y) = position(from);
        let (_, x1, _) = position(to);
        for (suffix, a, b, xa, xb) in [("f", from, to, x0, x1), ("r", to, from, x1, x0)] {
            edges.push(json!({
                "id": format!("{base}{suffix}"), "from": a, "to": b,
                "step_free": true, "minimum_clear_width_m": 1.2, "maximum_slope": 0.0,
                "segment": {"type": "surface", "map_id": scan, "floor_id": floor,
                    "path_points": [{"x": xa, "y": y, "z": 0.0}, {"x": xb, "y": y, "z": 0.0}]}
            }));
        }
        details.insert(
            base,
            json!({"kind": "corridor", "length_m": 5.0, "hazards": []}),
        );
    }
    serde_json::from_value(json!({
        "schema_version": 1,
        "id": format!("{scan}-nav"),
        "nodes": nodes.iter().map(|(id, floor, x, y)| json!({"id": id, "map_id": scan, "floor_id": floor, "x": x, "y": y, "z": 0.0})).collect::<Vec<_>>(),
        "edges": edges,
        "metadata": {
            "node_kinds": {"b": "door"},
            "door_nodes": {"door-0": "b"},
            "doors": {"door-0": {"clear_width_m": 0.9, "meets_clear_width": true, "issues": []}},
            "edges": details,
        }
    }))
    .unwrap()
}

fn analysis() -> Value {
    json!({
        "places": [
            {"id": "entrance", "category": "entrance", "name": "Entrance", "position_m": [10.0, 0.0, -0.5]},
            {"id": "room-201", "category": "room", "name": "Room 201", "position_m": [10.0, 3.5, -0.5]},
            {"id": "elevator-g", "category": "elevator", "name": "Elevator", "position_m": [0.0, 0.0, 0.5]},
            {"id": "elevator-1", "category": "elevator", "name": "Elevator", "position_m": [0.0, 3.5, 0.5]},
            {"id": "stairs-up", "category": "stairs", "name": "Stairwell", "position_m": [10.0, 3.5, 0.5]},
            {"id": "mcd", "category": "restaurant", "name": "McDonald's", "position_m": [0.0, 3.5, -1.5]}
        ],
        "hazards": [
            {"id": "stairs-0", "kind": "stairs", "severity": "barrier", "position_m": [10.0, 0.0, 0.5]}
        ],
        "signs": [
            {"id": "sign-000", "category": "exit", "text": "EXIT", "position_m": [5.0, 3.5, 1.0]},
            {"id": "sign-001", "category": "restroom", "text": "Restrooms", "position_m": [5.0, 0.0, 1.5]}
        ],
        "georef": {"latitude": 33.7756, "longitude": -84.3963, "heading_degrees": 0.0}
    })
}

async fn seeded(scan: &str, state: AppState) -> Router {
    state.graphs.put(two_floor_graph(scan)).await.unwrap();
    state.scans.put_analysis(scan, analysis()).await.unwrap();
    app(state)
}

fn by_label<'a>(body: &'a Value, label: &str) -> &'a Value {
    body["routes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["labels"].as_array().unwrap().iter().any(|l| l == label))
        .unwrap_or_else(|| panic!("no {label} route in {body:#}"))
}

fn types(route: &Value) -> Vec<&str> {
    route["features"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["type"].as_str().unwrap())
        .collect()
}

fn maneuvers(route: &Value) -> Vec<&str> {
    route["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["maneuver"].as_str().unwrap())
        .collect()
}

#[tokio::test]
async fn scan_routes_offer_stairs_and_an_elevator_alternative_across_floors() {
    let router = seeded("hall", AppState::default()).await;
    let request = json!({"from": {"place_id": "entrance"}, "to": {"place_id": "room-201"}});
    let (status, body) = send(&router, "POST", "/scans/hall/routes", Some(request)).await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["scope"]["scan_id"], "hall");
    assert_eq!(body["levels"].as_array().unwrap().len(), 2);
    assert_eq!(body["origin"]["place_id"], "entrance");
    assert_eq!(body["destination"]["level_id"], "L1");

    let fastest = by_label(&body, "fastest");
    assert_eq!(fastest["rank"], 1);
    assert_eq!(fastest["accessibility"]["status"], "not_accessible");
    assert_eq!(fastest["level_changes"], 1);
    let stairs = fastest["features"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["type"] == "stairs")
        .unwrap();
    assert_eq!(stairs["to_level_id"], "L1");
    assert_eq!(stairs["accessible"], false);
    assert_eq!(stairs["refs"]["hazard_id"], "stairs-0");
    assert_eq!(
        fastest["accessibility"]["blocking"][0]["feature_id"],
        stairs["id"]
    );
    assert!(
        maneuvers(fastest).contains(&"stairs_up"),
        "{:?}",
        maneuvers(fastest)
    );

    let accessible = by_label(&body, "accessible");
    assert_ne!(accessible["id"], fastest["id"]);
    assert_eq!(
        accessible["accessibility"]["status"], "unverified",
        "{:#}",
        accessible["accessibility"]
    );
    let kinds = types(accessible);
    assert!(
        kinds.contains(&"elevator") && kinds.contains(&"door"),
        "{kinds:?}"
    );
    assert!(!kinds.contains(&"stairs"));
    assert_eq!(*kinds.last().unwrap(), "destination");
    let steps = maneuvers(accessible);
    assert_eq!(steps.first(), Some(&"depart"));
    assert_eq!(steps.last(), Some(&"arrive"));
    assert!(
        steps.contains(&"enter_elevator") && steps.contains(&"exit_elevator"),
        "{steps:?}"
    );

    // Legs: walk on L0, ride the elevator, walk on L1 — drawable per floor.
    let legs = accessible["legs"].as_array().unwrap();
    let leg_types: Vec<&str> = legs.iter().map(|l| l["type"].as_str().unwrap()).collect();
    assert_eq!(leg_types, ["walk", "connector", "walk"]);
    assert_eq!(legs[0]["level_id"], "L0");
    assert_eq!(legs[2]["level_id"], "L1");
    assert_eq!(legs[1]["connector"]["type"], "elevator");
    assert!(legs[0]["polyline_m"].as_array().unwrap().len() >= 2);
    let lonlat = legs[0]["polyline_lonlat"][0].as_array().unwrap();
    assert!((lonlat[0].as_f64().unwrap() + 84.3963).abs() < 0.001);
    assert!((lonlat[1].as_f64().unwrap() - 33.7756).abs() < 0.001);
    // Feature ids are unique within a route and steps reference them.
    let ids: Vec<&str> = accessible["features"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["id"].as_str().unwrap())
        .collect();
    for step in accessible["steps"].as_array().unwrap() {
        for id in step["feature_ids"].as_array().unwrap() {
            assert!(ids.contains(&id.as_str().unwrap()), "dangling {id}");
        }
    }
    assert!(accessible["duration_s"].as_f64().unwrap() > fastest["duration_s"].as_f64().unwrap());
}

#[tokio::test]
async fn scan_routes_resolve_positions_coordinates_and_report_errors() {
    let router = seeded("annex", AppState::default()).await;
    let (status, body) = send(
        &router,
        "POST",
        "/scans/annex/routes",
        Some(json!({
            "from": {"position_m": [9.0, 0.0, 0.3]},
            "to": {"node_id": "annex:d"},
            "profiles": ["accessible"], "alternatives": 0
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["routes"].as_array().unwrap().len(), 1);
    assert_eq!(body["origin"]["node_id"], "annex:c");
    assert!(body["origin"]["snapped_distance_m"].as_f64().unwrap() > 0.9);

    // Latitude/longitude through the scan's georef, on a named level.
    let (status, body) = send(
        &router,
        "POST",
        "/scans/annex/routes",
        Some(json!({
            "from": {"latitude": 33.7756, "longitude": -84.3963, "level_id": "L1"},
            "to": {"place_id": "room-201"}, "profiles": ["fastest"]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["origin"]["node_id"], "annex:d");

    let (status, body) = send(
        &router,
        "POST",
        "/scans/annex/routes",
        Some(json!({
            "from": {"position_m": [50.0, 0.0, 50.0]}, "to": {"place_id": "room-201"}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "endpoint_not_found");

    let (status, body) = send(
        &router,
        "POST",
        "/scans/annex/routes",
        Some(json!({
            "from": {"place_id": "entrance", "node_id": "annex:a"}, "to": {"place_id": "room-201"}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "invalid_input");

    let (status, body) = send(
        &router,
        "POST",
        "/scans/missing/routes",
        Some(json!({
            "from": {"node_id": "x"}, "to": {"node_id": "y"}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"]["code"], "navigation_data_missing");

    let (status, body) = send(&router, "GET", "/scans/annex/levels", None).await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["levels"][1]["id"], "L1");
    let connector_types: Vec<&str> = body["connectors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["type"].as_str().unwrap())
        .collect();
    assert!(
        connector_types.contains(&"elevator") && connector_types.contains(&"stairs"),
        "{connector_types:?}"
    );
}

#[tokio::test]
async fn accessible_profile_reports_unreachable_when_only_stairs_connect() {
    let state = AppState::default();
    let mut analysis = analysis();
    analysis["places"]
        .as_array_mut()
        .unwrap()
        .retain(|p| p["category"] != "elevator");
    state.graphs.put(two_floor_graph("tower")).await.unwrap();
    state.scans.put_analysis("tower", analysis).await.unwrap();
    let router = app(state);
    let (status, body) = send(
        &router,
        "POST",
        "/scans/tower/routes",
        Some(json!({
            "from": {"place_id": "entrance"}, "to": {"place_id": "room-201"}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["unreachable"][0]["profile"], "accessible");
    assert!(
        body["routes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["accessibility"]["status"] == "not_accessible")
    );
}

#[tokio::test]
async fn nearby_finds_named_places_across_floors_like_a_maps_search() {
    let router = seeded("mall", AppState::default()).await;
    let search = |body: Value| send(&router, "POST", "/scans/mall/nearby", Some(body));

    let (status, body) =
        search(json!({"at": {"place_id": "entrance"}, "query": "mcdonalds"})).await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["scope"]["scan_id"], "mall");
    assert_eq!(body["bearing_reference"], "true_north");
    assert_eq!(body["total_matches"], 1, "{body:#}");
    let mcd = &body["results"][0];
    assert_eq!(mcd["name"], "McDonald's");
    assert_eq!(mcd["kind"], "place");
    assert_eq!(mcd["level_id"], "L1");
    assert_eq!(mcd["level_delta"], 1);
    assert_eq!(mcd["reachable"], true);
    assert_eq!(mcd["compass"], "W");
    assert_eq!(mcd["accessible_route"], "unverified");
    assert_eq!(mcd["route_to"], json!({"place_id": "mcd"}));
    assert_eq!(mcd["refs"]["place_id"], "mcd");
    let walk = mcd["walking_distance_m"].as_f64().unwrap();
    assert!(walk > mcd["distance_m"].as_f64().unwrap(), "{mcd:#}");
    assert!(mcd["walking_duration_s"].as_f64().unwrap() > 0.0);
    let lon = mcd["lon_lat"][0].as_f64().unwrap();
    // x = 0 lies on the georeference's meridian (the entrance, at x = 10, is east of it).
    assert!((lon + 84.3963).abs() < 1e-6, "{lon}");

    // The result routes directly.
    let (status, route) = send(
        &router,
        "POST",
        "/scans/mall/routes",
        Some(json!({
            "from": {"place_id": "entrance"}, "to": mcd["route_to"], "profiles": ["fastest"]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{route:#}");

    // Everyday words reach categories; signs count as places to find.
    let (_, body) = search(json!({"at": {"place_id": "entrance"}, "query": "bathroom"})).await;
    assert_eq!(body["results"][0]["name"], "Restrooms", "{body:#}");
    assert_eq!(body["results"][0]["kind"], "sign");

    // Browsing with no query: nearest first; same-floor filter; facing hints.
    let (_, body) = search(
        json!({"at": {"place_id": "entrance"}, "same_level_only": true, "heading_degrees": 0.0}),
    )
    .await;
    let results = body["results"].as_array().unwrap();
    assert!(!results.is_empty());
    assert!(results.iter().all(|r| r["level_id"] == "L0"), "{body:#}");
    assert!(results.iter().all(|r| r["relative_direction"].is_string()));
    let walks: Vec<f64> = results
        .iter()
        .map(|r| r["walking_distance_m"].as_f64().unwrap())
        .collect();
    assert!(walks.windows(2).all(|w| w[0] <= w[1]), "{walks:?}");
    assert!(
        results
            .iter()
            .all(|r| r["route_to"] != json!({"place_id": "entrance"}))
    );

    // Connectors list the floors they serve.
    let (_, body) = search(json!({"at": {"place_id": "entrance"}, "kinds": ["connector"]})).await;
    let elevator = body["results"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["category"] == "elevator")
        .unwrap();
    assert_eq!(elevator["serves_level_ids"], json!(["L0", "L1"]));
    assert_eq!(elevator["level_id"], "L0");

    let (_, body) = search(json!({"at": {"place_id": "entrance"}, "radius_m": 3.0})).await;
    assert!(
        body["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["walking_distance_m"].as_f64().unwrap() <= 3.0)
    );

    // A phone position far from the walked paths still searches, from the closest mapped spot.
    let (status, body) =
        search(json!({"at": {"position_m": [10.0, 0.0, 30.0]}, "query": "restroom"})).await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["results"][0]["name"], "Restrooms");
    assert!(
        body["notices"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n.as_str().unwrap().contains("from the mapped paths"))
    );
    assert!(body["results"][0]["distance_m"].as_f64().unwrap() > 25.0);

    let (status, body) = search(json!({"at": {"place_id": "entrance"}, "radius_m": 0})).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "invalid_input");
}

#[tokio::test]
#[ignore = "requires an isolated PostgreSQL database via INVIEW_TEST_DATABASE_URL"]
async fn postgres_building_routes_compose_aligned_scans_and_manual_connectors() {
    let base = std::env::var("INVIEW_TEST_DATABASE_URL").expect("Set INVIEW_TEST_DATABASE_URL");
    let admin = PgPool::connect(&base).await.unwrap();
    let schema = format!("inview_test_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
        .execute(&admin)
        .await
        .unwrap();
    let separator = if base.contains('?') { '&' } else { '?' };
    let url = format!("{base}{separator}options%5Bsearch_path%5D={schema}%2Cpublic");
    let pool = buildings::connect(&url, false).await.unwrap();
    let state = AppState {
        maps: Some(pool),
        ..AppState::default()
    };
    let router = seeded("demo-room", state).await;
    let scan: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let (status, _) = send(&router, "POST", "/scans", Some(scan)).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, building) = send(
        &router,
        "POST",
        "/api/buildings",
        Some(json!({"name": "Route Hall", "referenceCaptureId": "demo-room"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{building}");
    let id = building["id"].as_str().unwrap();

    // A volunteer-registered ramp between the floors' middles.
    let ramp = json!({"id": "ramp-1", "kind": "ramp", "from_m": [5.0, 0.0, 0.0], "to_m": [5.0, 3.5, 0.0], "name": "Atrium ramp"});
    let (status, body) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/connectors"),
        Some(ramp.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let (status, _) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/connectors"),
        Some(ramp),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, body) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}/connectors"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["connectors"][0]["kind"], "ramp");

    let (status, body) = send(&router, "GET", &format!("/api/buildings/{id}/levels"), None).await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert!(
        body["connectors"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["source"] == "manual" && c["type"] == "ramp"),
        "{body:#}"
    );

    let (status, body) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/routes"),
        Some(json!({
            "from": {"place_id": "entrance"}, "to": {"place_id": "room-201"}, "version": 1
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body:#}");
    assert_eq!(body["scope"]["building_id"], id);
    assert_eq!(body["scope"]["version"], 1);
    let (status, found) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/nearby"),
        Some(json!({
            "at": {"place_id": "entrance"}, "query": "McDonald's", "version": 1
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{found:#}");
    assert_eq!(found["scope"]["building_id"], id);
    assert_eq!(found["results"][0]["name"], "McDonald's");
    assert_eq!(found["results"][0]["accessible_route"], "unverified");
    let accessible = by_label(&body, "accessible");
    assert!(
        types(accessible).contains(&"ramp"),
        "{:?}",
        types(accessible)
    );
    assert!(
        maneuvers(accessible).contains(&"ramp_up"),
        "{:?}",
        maneuvers(accessible)
    );
}
