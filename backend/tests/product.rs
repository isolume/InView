use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{AppState, app, product_store::ProductStore};
use serde_json::{Value, json};
use tower::ServiceExt;
use uuid::Uuid;
const PASSWORD: &str = "a long test password";
fn map(name: &str) -> Value {
    json!({"createdAt":"2026-10-10T12:00:00Z","floorY":0,"footprints":[{"kind":"floor","center":[0,0],"size":[10,10],"yaw":0}],"points":[{"id":"e212ba01-d93b-4cc1-90b3-e71835ce3536","kind":"destination","name":name,"position":[1,0,1],"source":"manual","confidence":1,"requiresAssistance":false}],"requiresMeasuredFloorCoverage":true})
}
fn upload(client: &str, name: &str) -> Value {
    json!({"client_submission_id":client,"venue_id":"student-center-east","floor":2,"map":map(name),"notes":"Authorized test submission","authorized_space":true})
}
async fn request(
    router: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(token) = token {
        request = request.header("Authorization", format!("Bearer {token}"));
    }
    if body.is_some() {
        request = request.header("Content-Type", "application/json");
    }
    let response = router
        .clone()
        .oneshot(
            request
                .body(body.map_or(Body::empty(), |v| Body::from(v.to_string())))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap()
        },
    )
}
async fn signup(router: &Router, email: &str) -> String {
    let (status, data) = request(
        router,
        "POST",
        "/api/accounts/register",
        None,
        Some(json!({"email":email,"password":PASSWORD,"name":"Test User"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(data["account"]["role"], "user");
    data["token"].as_str().unwrap().into()
}
async fn admin(router: &Router) -> String {
    let (status, data) = request(
        router,
        "POST",
        "/api/accounts/login",
        None,
        Some(json!({"email":"admin@example.test","password":PASSWORD})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    data["token"].as_str().unwrap().into()
}
fn setup() -> (AppState, Router) {
    let state = AppState::default();
    state
        .product
        .bootstrap_admin("admin@example.test", PASSWORD)
        .unwrap();
    let router = app(state.clone());
    (state, router)
}
fn checks(revision: u64) -> Value {
    json!({"expected_revision":revision,"geometry_reviewed":true,"routes_reviewed":true,"floor_links_reviewed":true})
}

#[tokio::test]
async fn accounts_revoke_sessions_and_isolate_owned_private_submissions() {
    let (_, router) = setup();
    let alice = signup(&router, "ALICE@example.test").await;
    let bob = signup(&router, "bob@example.test").await;
    let (_, mine) = request(&router, "GET", "/api/accounts/me", Some(&alice), None).await;
    assert_eq!(mine["email"], "alice@example.test");
    assert_eq!(
        request(
            &router,
            "POST",
            "/api/accounts/register",
            None,
            Some(json!({"email":"evil@example.test","password":PASSWORD,"role":"admin"}))
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        request(
            &router,
            "POST",
            "/api/accounts/login",
            None,
            Some(json!({"email":"alice@example.test","password":"incorrect"}))
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (_, submission) = request(
        &router,
        "POST",
        "/api/submissions",
        Some(&alice),
        Some(upload(&Uuid::new_v4().to_string(), "Original destination")),
    )
    .await;
    let path = format!("/api/submissions/{}", submission["id"].as_str().unwrap());
    assert_eq!(
        request(&router, "GET", &path, Some(&bob), None).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(&router, "GET", &path, None, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(&router, "GET", "/api/admin/submissions", Some(&bob), None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        request(
            &router,
            "PATCH",
            &path.replace("/api/submissions/", "/api/admin/submissions/"),
            Some(&bob),
            Some(json!({"expected_revision":1,"map":map("Tampered")}))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (_, bob_list) = request(&router, "GET", "/api/submissions", Some(&bob), None).await;
    assert_eq!(bob_list, json!([]));
    assert_eq!(
        request(&router, "POST", "/api/accounts/logout", Some(&alice), None)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        request(&router, "GET", "/api/accounts/me", Some(&alice), None)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn publication_keeps_sources_immutable_and_requires_current_review_revision() {
    let (_, router) = setup();
    let user = signup(&router, "contributor@example.test").await;
    let admin = admin(&router).await;
    let client = Uuid::new_v4().to_string();
    let payload = upload(&client, "Before review");
    let (created, submission) = request(
        &router,
        "POST",
        "/api/submissions",
        Some(&user),
        Some(payload.clone()),
    )
    .await;
    assert_eq!(created, StatusCode::CREATED);
    let id = submission["id"].as_str().unwrap();
    let path = format!("/api/admin/submissions/{id}");
    let (retry, receipt) = request(
        &router,
        "POST",
        "/api/submissions",
        Some(&user),
        Some(payload.clone()),
    )
    .await;
    assert_eq!(retry, StatusCode::OK);
    assert_eq!(receipt["id"], id);
    assert_eq!(
        request(
            &router,
            "POST",
            "/api/submissions",
            Some(&user),
            Some(upload(&client, "Different source"))
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let (_, empty) = request(
        &router,
        "GET",
        "/api/venues/student-center-east/maps",
        None,
        None,
    )
    .await;
    assert_eq!(empty["maps"], json!([]));
    let (_, edited) = request(
        &router,
        "PATCH",
        &path,
        Some(&admin),
        Some(json!({"expected_revision":1,"map":map("Reviewed destination"),"status":"in_review"})),
    )
    .await;
    assert_eq!(edited["revision"], 2);
    assert_eq!(edited["original_map"]["points"][0]["name"], "Before review");
    assert_eq!(
        request(
            &router,
            "POST",
            &format!("{path}/publish"),
            Some(&admin),
            Some(checks(1))
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let mut unchecked = checks(2);
    unchecked["routes_reviewed"] = json!(false);
    assert_eq!(
        request(
            &router,
            "POST",
            &format!("{path}/publish"),
            Some(&admin),
            Some(unchecked)
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let (_, release) = request(
        &router,
        "POST",
        &format!("{path}/publish"),
        Some(&admin),
        Some(checks(2)),
    )
    .await;
    assert_eq!(release["version"], 1);
    assert_eq!(release["ar_ready"], false);
    assert_eq!(release["origin"], "admin_reviewed");
    let (_, same) = request(
        &router,
        "POST",
        &format!("{path}/publish"),
        Some(&admin),
        Some(checks(2)),
    )
    .await;
    assert_eq!(same["id"], release["id"]);
    let (_, changed) = request(
        &router,
        "PATCH",
        &path,
        Some(&admin),
        Some(json!({"expected_revision":2,"map":map("Next release")})),
    )
    .await;
    assert_eq!(changed["revision"], 3);
    let (_, public) = request(
        &router,
        "GET",
        "/api/venues/student-center-east/maps",
        None,
        None,
    )
    .await;
    assert_eq!(
        public["maps"][0]["map"]["points"][0]["name"],
        "Reviewed destination"
    );
    assert!(public["maps"][0].get("published_by").is_none());
    let (_, release2) = request(
        &router,
        "POST",
        &format!("{path}/publish"),
        Some(&admin),
        Some(checks(3)),
    )
    .await;
    assert_eq!(release2["version"], 2);
    let (_, old) = request(
        &router,
        "GET",
        "/api/venues/student-center-east/maps/2/versions/1",
        None,
        None,
    )
    .await;
    assert_eq!(old["map"]["points"][0]["name"], "Reviewed destination");
}

#[tokio::test]
async fn corrected_upload_retries_survive_later_review_and_cannot_edit_other_accounts() {
    let (_, router) = setup();
    let user = signup(&router, "owner@example.test").await;
    let other = signup(&router, "other@example.test").await;
    let admin = admin(&router).await;
    let (_, submission) = request(
        &router,
        "POST",
        "/api/submissions",
        Some(&user),
        Some(upload(&Uuid::new_v4().to_string(), "First scan")),
    )
    .await;
    let id = submission["id"].as_str().unwrap();
    let path = format!("/api/admin/submissions/{id}");
    assert_eq!(
        request(
            &router,
            "PATCH",
            &path,
            Some(&admin),
            Some(json!({"expected_revision":1,"status":"changes_requested"}))
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let (_,changed)=request(&router,"PATCH",&path,Some(&admin),Some(json!({"expected_revision":1,"status":"changes_requested","review_note":"Capture the doorway again."}))).await;
    assert_eq!(changed["revision"], 2);
    let correction = json!({"client_submission_id":Uuid::new_v4().to_string(),"expected_revision":2,"map":map("New scan"),"notes":"Doorway captured","authorized_space":true});
    let resubmit = format!("/api/submissions/{id}/resubmit");
    assert_eq!(
        request(
            &router,
            "POST",
            &resubmit,
            Some(&other),
            Some(correction.clone())
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (_, receipt) = request(
        &router,
        "POST",
        &resubmit,
        Some(&user),
        Some(correction.clone()),
    )
    .await;
    assert_eq!(receipt["revision"], 3);
    assert_eq!(receipt["status"], "submitted");
    assert_eq!(
        request(
            &router,
            "POST",
            &format!("{path}/publish"),
            Some(&admin),
            Some(checks(3))
        )
        .await
        .0,
        StatusCode::OK
    );
    let (status, receipt) =
        request(&router, "POST", &resubmit, Some(&user), Some(correction)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(receipt["status"], "published");
    let (_, detail) = request(
        &router,
        "GET",
        &format!("/api/submissions/{id}"),
        Some(&user),
        None,
    )
    .await;
    assert_eq!(detail["sources"].as_array().unwrap().len(), 2);
    assert_eq!(detail["original_map"]["points"][0]["name"], "First scan");
    assert_eq!(detail["map"]["points"][0]["name"], "New scan");
}

#[tokio::test]
async fn durable_restart_restores_hashed_sessions_and_published_maps() {
    let path = std::env::temp_dir().join(format!("inview-product-test-{}", Uuid::new_v4()));
    let store = ProductStore::open(&path).unwrap();
    store
        .bootstrap_admin("admin@example.test", PASSWORD)
        .unwrap();
    assert!(ProductStore::open(&path).is_err());
    let state = AppState {
        product: store.clone(),
        ..AppState::default()
    };
    let router = app(state);
    let user = signup(&router, "persistent@example.test").await;
    let admin = admin(&router).await;
    let (_, submission) = request(
        &router,
        "POST",
        "/api/submissions",
        Some(&user),
        Some(upload(&Uuid::new_v4().to_string(), "Durable map")),
    )
    .await;
    let id = submission["id"].as_str().unwrap();
    assert_eq!(
        request(
            &router,
            "POST",
            &format!("/api/admin/submissions/{id}/publish"),
            Some(&admin),
            Some(checks(1))
        )
        .await
        .0,
        StatusCode::OK
    );
    let disk = std::fs::read_to_string(path.join("product.json")).unwrap();
    assert!(!disk.contains(PASSWORD));
    assert!(!disk.contains(&user));
    assert!(disk.contains("$argon2id$"));
    drop(router);
    drop(store);
    let reopened = ProductStore::open(&path).unwrap();
    let state = AppState {
        product: reopened.clone(),
        ..AppState::default()
    };
    let router = app(state);
    assert_eq!(
        request(&router, "GET", "/api/accounts/me", Some(&user), None)
            .await
            .0,
        StatusCode::OK
    );
    let (_, maps) = request(
        &router,
        "GET",
        "/api/venues/student-center-east/maps",
        None,
        None,
    )
    .await;
    assert_eq!(maps["maps"][0]["map"]["points"][0]["name"], "Durable map");
    assert_eq!(
        request(&router, "POST", "/api/accounts/logout", Some(&user), None)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    drop(router);
    drop(reopened);
    let store = ProductStore::open(&path).unwrap();
    assert!(store.account(&user).is_err());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn submissions_reject_unapproved_venues_missing_permission_and_bad_geometry() {
    let (_, router) = setup();
    let user = signup(&router, "validation@example.test").await;
    for field in ["venue", "floor", "permission", "geometry", "point"] {
        let mut value = upload(&Uuid::new_v4().to_string(), "A room");
        match field {
            "venue" => value["venue_id"] = json!("someone-elses-building"),
            "floor" => value["floor"] = json!(4),
            "permission" => value["authorized_space"] = json!(false),
            "geometry" => value["map"]["footprints"][0]["size"] = json!([0, 5]),
            _ => value["map"]["points"][0]["position"] = json!([1, 2]),
        }
        assert_eq!(
            request(
                &router,
                "POST",
                "/api/submissions",
                Some(&user),
                Some(value)
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY,
            "{field}"
        );
    }
    assert_eq!(
        request(
            &router,
            "GET",
            "/api/venues/other-building/maps",
            None,
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[test]
fn map_contract_rejects_dates_spans_degenerate_outlines_and_duplicate_feature_ids() {
    use inview_backend::product_store::validate_map;
    assert!(validate_map(&map("Valid floor")).is_ok());
    for case in [
        "date",
        "numeric_date",
        "size",
        "height",
        "span",
        "degenerate",
        "duplicate",
        "furniture",
        "boolean",
        "coverage",
        "polygon_count",
        "point_count",
        "footprint_count",
    ] {
        let mut value = map("Room");
        match case {
            "date" => value["createdAt"] = json!("not a date"),
            "numeric_date" => value["createdAt"] = json!(123),
            "size" => value["footprints"][0]["size"] = json!([501, 1]),
            "height" => value["points"][0]["position"] = json!([1, 1001, 1]),
            "span" => value["points"][0]["position"] = json!([600, 0, 0]),
            "degenerate" => value["footprints"][0]["polygon"] = json!([[0, 0], [1, 0], [2, 0]]),
            "duplicate" => {
                value["footprints"][0]["id"] = json!("E212BA01-D93B-4CC1-90B3-E71835CE3536")
            }
            "furniture" => value["footprints"][0]["furniture"] = json!("unknown_future_chair"),
            "boolean" => value["points"][0]["requiresAssistance"] = json!("yes"),
            "coverage" => value["footprints"][0]["kind"] = json!("wall"),
            "polygon_count" => value["footprints"][0]["polygon"] = json!(vec![[0, 0]; 129]),
            "point_count" => value["points"] = json!(vec![value["points"][0].clone(); 1001]),
            _ => value["footprints"] = json!(vec![value["footprints"][0].clone(); 10001]),
        }
        assert!(validate_map(&value).is_err(), "{case}");
    }
}

#[tokio::test]
async fn configured_processing_credentials_are_separate_from_accounts_and_graph_publication() {
    const PROCESSING: &str = "test-processing-token-with-at-least-32-characters";
    let path = std::env::temp_dir().join(format!("inview-publication-test-{}", Uuid::new_v4()));
    let (mut state, _) = setup();
    state.api_token = Some(PROCESSING.into());
    state.published_graphs = inview_backend::store::GraphStore::open(&path).unwrap();
    let router = app(state.clone());
    let user = signup(&router, "public-reader@example.test").await;
    let admin = admin(&router).await;
    for path in [
        "/health",
        "/scans",
        "/streams/missing",
        "/graphs",
        "/api/buildings",
    ] {
        assert_eq!(
            request(&router, "GET", path, None, None).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            request(&router, "GET", path, Some(&user), None).await.0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        request(&router, "GET", "/health", Some(PROCESSING), None)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        request(
            &router,
            "GET",
            "/api/venues/student-center-east/maps",
            None,
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    let mut graph: Value = serde_json::from_str(include_str!("../examples/graph.json")).unwrap();
    graph["metadata"]["venue_id"] = json!("demo-building");
    graph["metadata"]["review_status"] = json!("draft");
    let route: Value = serde_json::from_str(include_str!("../examples/route.json")).unwrap();
    assert_eq!(
        request(
            &router,
            "PUT",
            "/graphs/demo-building",
            Some(PROCESSING),
            Some(graph.clone())
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(&router, "GET", "/graphs/demo-building", None, None)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &router,
            "POST",
            "/graphs/demo-building/routes",
            None,
            Some(route.clone())
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &router,
            "GET",
            "/api/admin/graphs/demo-building",
            Some(&user),
            None
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        request(
            &router,
            "GET",
            "/api/admin/graphs/demo-building",
            Some(PROCESSING),
            None
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (_, review) = request(
        &router,
        "GET",
        "/api/admin/graphs/demo-building",
        Some(&admin),
        None,
    )
    .await;
    let approval = json!({"expected_fingerprint":review["fingerprint"], "geometry_reviewed":true,
        "routes_reviewed":true, "floor_links_reviewed":true});
    let publish = "/api/admin/graphs/demo-building/publish";
    assert_eq!(
        request(
            &router,
            "POST",
            publish,
            Some(PROCESSING),
            Some(approval.clone())
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let mut unchecked = approval.clone();
    unchecked["routes_reviewed"] = json!(false);
    assert_eq!(
        request(&router, "POST", publish, Some(&admin), Some(unchecked))
            .await
            .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        request(
            &router,
            "POST",
            publish,
            Some(&admin),
            Some(approval.clone())
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(
            &router,
            "POST",
            "/graphs/demo-building/routes",
            None,
            Some(route)
        )
        .await
        .0,
        StatusCode::OK
    );
    let (_, published) = request(&router, "GET", "/graphs/demo-building", None, None).await;
    assert!(
        published["metadata"]["publication"]
            .get("reviewed_by")
            .is_none()
    );
    assert_eq!(published["metadata"]["review_status"], "reviewed");
    assert_eq!(
        state.graphs.get("demo-building").await.unwrap().metadata["review_status"],
        "draft"
    );
    assert_eq!(
        published["metadata"]["publication"]["source_fingerprint"],
        review["fingerprint"]
    );
    graph["metadata"]["draft_note"] = json!("unreviewed replacement");
    assert_eq!(
        request(
            &router,
            "PUT",
            "/graphs/demo-building",
            Some(PROCESSING),
            Some(graph)
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(&router, "POST", publish, Some(&admin), Some(approval))
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        request(&router, "GET", "/graphs/demo-building", None, None)
            .await
            .1,
        published
    );
    let reopened = inview_backend::store::GraphStore::open(&path).unwrap();
    assert_eq!(
        reopened.get("demo-building").await.unwrap().metadata["publication"]["source_fingerprint"],
        review["fingerprint"]
    );
    assert_eq!(std::fs::read_dir(path.join("history")).unwrap().count(), 1);
    std::fs::remove_dir_all(path).unwrap();
}
