use std::sync::Arc;

use axum::{
    body::Body,
    http::{Request, StatusCode, header},
};
use inview_backend::{AppState, app};
use tower::ServiceExt;

#[tokio::test]
async fn studio_shell_is_public_but_capture_data_requires_bearer_token() {
    let state = AppState {
        api_token: Some(Arc::from("long-private-test-token-0123456789")),
        ..AppState::default()
    };
    let router = app(state);
    let page = router
        .clone()
        .oneshot(Request::builder().uri("/").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(page.status(), StatusCode::OK);
    assert!(
        page.headers()
            .get(header::CONTENT_SECURITY_POLICY)
            .is_some()
    );
    assert_eq!(
        page.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/html; charset=utf-8"
    );
    for (path, content_type) in [
        ("/studio/assets/studio.css", "text/css; charset=utf-8"),
        ("/studio/assets/studio.js", "text/javascript; charset=utf-8"),
        (
            "/studio/assets/OrbitControls.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/studio/assets/three.module.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/studio/assets/nav-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/studio/assets/nav-map.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/studio/assets/nav-scene.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/studio/assets/nav-viewer.js",
            "text/javascript; charset=utf-8",
        ),
    ] {
        let asset = router
            .clone()
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(asset.status(), StatusCode::OK);
        assert_eq!(
            asset.headers().get(header::CONTENT_TYPE).unwrap(),
            content_type
        );
    }
    let denied = router
        .clone()
        .oneshot(
            Request::builder()
                .uri("/scans")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let allowed = router
        .clone()
        .oneshot(
            Request::builder()
                .uri("/scans")
                .header(
                    header::AUTHORIZATION,
                    "Bearer long-private-test-token-0123456789",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
    let unknown = router
        .oneshot(
            Request::builder()
                .uri("/studio/assets/unknown.js")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
}
