use axum::{
    Router,
    body::{Body, to_bytes},
    http::{HeaderMap, Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{AppState, app};
use serde_json::{Value, json};
use tower::ServiceExt;

/// A valid 1x1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    body: Option<Value>,
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(
            body.map_or_else(Vec::new, |b| b.to_string().into_bytes()),
        ))
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let (status, headers) = (response.status(), response.headers().clone());
    let bytes = to_bytes(response.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, headers, bytes)
}

async fn json_of(router: &Router, uri: &str) -> (StatusCode, Value) {
    let (status, _, bytes) = call(router, "GET", uri, None).await;
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn item(rank: u32, kind: &str, severity: &str, importance: f64) -> Value {
    json!({"id": format!("hl-{kind}-{rank}"), "rank": rank, "kind": kind, "severity": severity,
           "importance": importance, "title": format!("{kind} {rank}"), "reason": "why",
           "position_xz_m": [1.0, 2.0], "geometry": {"type": "point", "xz": [[1.0, 2.0]]}})
}

async fn seeded(highlights: Option<Value>) -> Router {
    let state = AppState::default();
    let router = app(state.clone());
    let scan: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let (status, _, _) = call(&router, "POST", "/scans", Some(scan)).await;
    assert_eq!(status, StatusCode::CREATED);
    let mut analysis =
        json!({"schema_version": 1, "scan_id": "demo-room", "frame": "shared_arkit_session"});
    if let Some(h) = highlights {
        analysis["highlights"] = h;
    }
    state
        .scans
        .put_analysis("demo-room", analysis)
        .await
        .unwrap();
    router
}

fn highlights() -> Value {
    json!({
        "schema_version": 1, "floor_id": "ground",
        "items": [
            item(1, "barrier", "barrier", 0.96),
            item(2, "door", "barrier", 0.92),
            item(3, "narrow_passage", "warning", 0.61),
            item(4, "access_feature", "asset", 0.80),
            item(5, "wayfinding", "info", 0.42),
        ],
        "image": {"png_base64": PNG, "width": 1, "height": 1, "map_width_px": 1, "map_height_px": 1, "scale": 1.0},
    })
}

#[tokio::test]
async fn serves_ranked_findings_without_the_heavy_image_by_default() {
    let router = seeded(Some(highlights())).await;
    let (status, body) = json_of(&router, "/scans/demo-room/highlights").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["total"].as_u64(), body["matched"].as_u64()),
        (Some(5), Some(5))
    );
    assert_eq!(body["items"][0]["title"], "barrier 1");
    assert_eq!(body["scan_id"], "demo-room");
    assert_eq!(body["image_url"], "/scans/demo-room/highlights.png");
    assert!(body["image"].get("png_base64").is_none(), "{body}");
    assert_eq!(body["image"]["width"], 1);

    let (_, with_image) = json_of(&router, "/scans/demo-room/highlights?image=true").await;
    assert_eq!(with_image["image"]["png_base64"], PNG);
}

#[tokio::test]
async fn filters_by_kind_severity_importance_and_limit_without_renumbering() {
    let router = seeded(Some(highlights())).await;
    let ranks = |body: &Value| -> Vec<u64> {
        body["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["rank"].as_u64().unwrap())
            .collect()
    };
    let (_, body) = json_of(
        &router,
        "/scans/demo-room/highlights?kinds=door,access_feature",
    )
    .await;
    assert_eq!(ranks(&body), [2, 4]);
    assert_eq!(
        (body["matched"].as_u64(), body["total"].as_u64()),
        (Some(2), Some(5))
    );
    let (_, body) = json_of(&router, "/scans/demo-room/highlights?severity=barrier").await;
    assert_eq!(ranks(&body), [1, 2]);
    let (_, body) = json_of(&router, "/scans/demo-room/highlights?min_importance=0.8").await;
    assert_eq!(ranks(&body), [1, 2, 4]);
    let (_, body) = json_of(
        &router,
        "/scans/demo-room/highlights?severity=barrier,warning&limit=2",
    )
    .await;
    assert_eq!(ranks(&body), [1, 2]);
    let (_, body) = json_of(&router, "/scans/demo-room/highlights?kinds=route").await;
    assert_eq!(body["matched"], 0);
}

#[tokio::test]
async fn rejects_bad_queries_before_touching_the_data() {
    let router = seeded(Some(highlights())).await;
    for uri in [
        "/scans/demo-room/highlights?min_importance=2",
        "/scans/demo-room/highlights?min_importance=NaN",
        "/scans/demo-room/highlights?limit=0",
        "/scans/demo-room/highlights?limit=1000",
        "/scans/demo-room/highlights?kinds=DOOR;drop",
        "/scans/demo-room/highlights?kinds=",
        "/scans/demo-room/highlights?surprise=1",
    ] {
        let (status, body) = json_of(&router, uri).await;
        assert!(
            status == StatusCode::UNPROCESSABLE_ENTITY || status == StatusCode::BAD_REQUEST,
            "{uri}: {status} {body}"
        );
    }
}

#[tokio::test]
async fn serves_the_image_as_a_png() {
    let router = seeded(Some(highlights())).await;
    let (status, headers, bytes) =
        call(&router, "GET", "/scans/demo-room/highlights.png", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "image/png");
    assert_eq!(bytes, STANDARD.decode(PNG).unwrap());
    assert_eq!(headers["x-content-type-options"], "nosniff");
}

#[tokio::test]
async fn reports_what_is_missing_precisely() {
    let router = seeded(None).await;
    let (status, body) = json_of(&router, "/scans/demo-room/highlights").await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (StatusCode::NOT_FOUND, Some("highlights_not_found"))
    );
    let (status, _, _) = call(&router, "GET", "/scans/demo-room/highlights.png", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, body) = json_of(&router, "/scans/nope/highlights").await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (StatusCode::NOT_FOUND, Some("scan_not_found"))
    );

    // A scan that was never analysed.
    let state = AppState::default();
    let router = app(state);
    let scan: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    call(&router, "POST", "/scans", Some(scan)).await;
    let (_, body) = json_of(&router, "/scans/demo-room/highlights").await;
    assert_eq!(body["error"]["code"], "analysis_not_found");

    // A corrupt stored image is a server fault, not a crash.
    let router = seeded(Some(
        json!({"items": [], "image": {"png_base64": "!!not base64!!"}}),
    ))
    .await;
    let (status, _, _) = call(&router, "GET", "/scans/demo-room/highlights.png", None).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
}
