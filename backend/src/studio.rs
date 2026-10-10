//! Static, data-free studio shell. All scan and building data is fetched through authenticated APIs.
use axum::{
    extract::Path,
    http::{StatusCode, header},
    response::IntoResponse,
};

const POLICY: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

pub async fn page() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
            (header::CONTENT_SECURITY_POLICY, POLICY),
            (header::REFERRER_POLICY, "no-referrer"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        include_str!("../studio/index.html"),
    )
}

pub async fn asset(Path(name): Path<String>) -> impl IntoResponse {
    let (mime, bytes): (&str, &'static [u8]) = match name.as_str() {
        "studio.css" => (
            "text/css; charset=utf-8",
            include_bytes!("../studio/studio.css"),
        ),
        "studio.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/studio.js"),
        ),
        "nav-model.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/nav-model.js"),
        ),
        "nav-map.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/nav-map.js"),
        ),
        "nav-scene.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/nav-scene.js"),
        ),
        "nav-viewer.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/nav-viewer.js"),
        ),
        "three.module.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/vendor/three.module.js"),
        ),
        "OrbitControls.js" => (
            "text/javascript; charset=utf-8",
            include_bytes!("../studio/vendor/OrbitControls.js"),
        ),
        _ => {
            return (
                StatusCode::NOT_FOUND,
                [(header::CONTENT_TYPE, "text/plain")],
                b"Not found".as_slice(),
            )
                .into_response();
        }
    };
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, mime),
            (header::CACHE_CONTROL, "public, max-age=3600"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        bytes,
    )
        .into_response()
}
