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

/// Every relative ES module import in the studio must be served, or the page fails to boot.
#[tokio::test]
async fn studio_module_imports_are_all_served_and_data_free() {
    let router = app(AppState::default());
    let mut pending = vec!["studio.js".to_string()];
    let mut seen = std::collections::BTreeSet::new();
    while let Some(name) = pending.pop() {
        if !seen.insert(name.clone()) {
            continue;
        }
        let response = router
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/studio/assets/{name}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "{name} is not served");
        let body = to_bytes(response.into_body(), 4 * 1024 * 1024)
            .await
            .unwrap();
        let source = String::from_utf8_lossy(&body);
        if name.starts_with("nav-") {
            assert!(
                !source.contains("innerHTML"),
                "{name} must insert analysis data with textContent only"
            );
        }
        // Follow single- and multi-line `import ... from './x.js';` statements.
        for (index, _) in source.match_indices("from './") {
            let rest = &source[index + "from './".len()..];
            let end = rest.find('\'').unwrap();
            pending.push(rest[..end].to_string());
        }
    }
    for module in [
        "nav-model.js",
        "nav-map.js",
        "nav-scene.js",
        "nav-viewer.js",
        "three.module.js",
        "OrbitControls.js",
    ] {
        assert!(seen.contains(module), "{module} is not imported");
    }
}
