use std::sync::Arc;

use axum::{
    body::{Body, to_bytes},
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
    let html = to_bytes(page.into_body(), 1024 * 1024).await.unwrap();
    assert!(String::from_utf8_lossy(&html).contains("Spaces, made visible"));
    for (path, content_type) in [
        ("/studio/assets/studio.css", "text/css; charset=utf-8"),
        ("/studio/assets/studio.js", "text/javascript; charset=utf-8"),
        (
            "/studio/assets/three.module.js",
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
