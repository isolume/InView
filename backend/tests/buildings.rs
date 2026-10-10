use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{AppState, app, buildings};
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
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn unavailable_database_does_not_break_existing_routes() {
    let router = app(AppState::default());
    let (status, _) = send(&router, "GET", "/api/buildings", None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    let (status, _) = send(&router, "GET", "/health", None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn postgres_building_frame_snapshots_and_pose_evidence() {
    let Ok(base) = std::env::var("INVIEW_TEST_DATABASE_URL") else {
        eprintln!("Set INVIEW_TEST_DATABASE_URL for isolated PostgreSQL integration test");
        return;
    };
    let admin = PgPool::connect(&base).await.unwrap();
    let schema = format!("inview_test_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
        .execute(&admin)
        .await
        .unwrap();
    let separator = if base.contains('?') { '&' } else { '?' };
    let url = format!("{base}{separator}options%5Bsearch_path%5D={schema}%2Cpublic");
    let require_timescale = std::env::var("INVIEW_TEST_REQUIRE_TIMESCALE").as_deref() == Ok("1");
    let pool = buildings::connect(&url, require_timescale).await.unwrap();
    if require_timescale {
        let tls: bool =
            sqlx::query_scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(tls, "TigerData test connection must use TLS");
        let hypertable: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM timescaledb_information.hypertables
             WHERE hypertable_schema=current_schema() AND hypertable_name='pose_observations')",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(
            hypertable,
            "TigerData must store pose evidence in a hypertable"
        );
    }
    let router = app(AppState {
        maps: Some(pool.clone()),
        ..AppState::default()
    });
    let mut scan: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let (status, _) = send(&router, "POST", "/scans", Some(scan.clone())).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, building) = send(
        &router,
        "POST",
        "/api/buildings",
        Some(json!({"name":"Test Hall", "referenceCaptureId":"demo-room"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{building}");
    assert_eq!(building["version"], 1);
    assert_eq!(building["alignments"][0]["status"], "reference");
    let id = building["id"].as_str().unwrap();
    let (status, observed) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}/observations"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{observed}");
    assert_eq!(
        observed["poses"][0]["positionMeters"],
        json!([0., 1.4, 1.8])
    );
    assert_eq!(
        observed["timeSource"],
        "arkit_relative_anchored_to_device_clock_or_ingest"
    );
    let (status, _) = send(
        &router,
        "POST",
        "/api/buildings",
        Some(json!({"name":"Duplicate", "referenceCaptureId":"demo-room"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    scan["id"] = json!("other-room");
    let (status, _) = send(&router, "POST", "/scans", Some(scan)).await;
    assert_eq!(status, StatusCode::CREATED);
    let payload = json!({"captureId":"other-room", "expectedVersion":1, "method":"control_points", "pairs":[
      {"scan":[0.,0.,0.], "building":[10.,2.,20.]},
      {"scan":[1.,0.,0.], "building":[10.,2.,21.]},
      {"scan":[0.,0.,1.], "building":[9.,2.,20.]}
    ]});
    let (status, aligned) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/alignments"),
        Some(payload.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{aligned}");
    assert_eq!(aligned["version"], 2);
    assert_eq!(aligned["scanCount"], 2);
    assert_eq!(aligned["alignments"][1]["status"], "provisional");
    let (status, stale) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/alignments"),
        Some(payload),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{stale}");
    let (status, v1) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}?version=1"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v1["scanCount"], 1);
    let (status, v2_poses) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}/observations?version=2"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{v2_poses}");
    assert_eq!(v2_poses["poses"].as_array().unwrap().len(), 2);
    let (status, v1_poses) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}/observations?version=1"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v1_poses["poses"].as_array().unwrap().len(), 1);

    let mut building_marker = [
        1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 6., 0., 9., 1.,
    ];
    let scan_marker = [
        1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 1., 0., 2., 1.,
    ];
    let (status, v3) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/alignments"),
        Some(json!({
            "captureId":"other-room", "expectedVersion":2, "method":"marker",
            "buildingMarker":building_marker, "scanMarker":scan_marker
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{v3}");
    assert_eq!(v3["version"], 3);
    assert_eq!(v3["scanCount"], 2);
    assert_eq!(v3["alignments"][1]["transform4x4ColumnMajor"][12], 5.);
    let (status, v2) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}?version=2"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v2["alignments"][1]["version"], 2);
    let (status, preview) = send(
        &router,
        "GET",
        &format!("/api/buildings/{id}/overview?version=3"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    let observations = preview["observations"].as_array().unwrap();
    assert_eq!(observations.len(), 2);
    let reference = observations
        .iter()
        .find(|o| o["captureId"] == "demo-room")
        .unwrap();
    assert_eq!(reference["status"], "reference");
    assert_eq!(reference["pathXZ"], json!([[0., 1.8]]));
    assert_eq!(reference["surfaceSamplesXZ"].as_array().unwrap().len(), 3);
    let marker = observations
        .iter()
        .find(|o| o["captureId"] == "other-room")
        .unwrap();
    assert_eq!(marker["method"], "marker");
    assert_eq!(marker["pathXZ"], json!([[5., 8.8]]));
    assert!(
        preview["notice"]
            .as_str()
            .unwrap()
            .contains("NOT verified walkable")
    );
    building_marker[0] = 2.;
    let (status, _) = send(
        &router,
        "POST",
        &format!("/api/buildings/{id}/alignments"),
        Some(json!({
            "captureId":"other-room", "expectedVersion":3, "method":"marker",
            "buildingMarker":building_marker, "scanMarker":scan_marker
        })),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);

    drop(router);
    pool.close().await;
    sqlx::query(&format!("DROP SCHEMA \"{schema}\" CASCADE"))
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
}
