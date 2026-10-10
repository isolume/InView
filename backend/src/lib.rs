pub mod alignment;
pub mod api;
pub mod capture;
pub mod display_mesh;
pub mod error;
pub mod geometry;
pub mod graph;
pub mod model_meshes;
pub mod recognition_service;
pub mod recognized_objects;
pub mod routing;
pub mod scan_api;
pub mod scene;
pub mod store;
pub mod stream_api;
pub mod streaming;

use axum::{Router, extract::DefaultBodyLimit, routing::get};
use tower_http::trace::TraceLayer;

use store::{GraphStore, ScanStore};

#[derive(Clone, Default)]
pub struct AppState {
    pub graphs: GraphStore,
    pub scans: ScanStore,
    pub streams: streaming::StreamStore,
}

pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(api::health))
        .route(
            "/streams",
            axum::routing::post(stream_api::create).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route("/streams/{id}", get(stream_api::summary))
        .route(
            "/streams/{id}/chunks/{sequence}",
            axum::routing::put(stream_api::chunk)
                .layer(DefaultBodyLimit::max(streaming::MAX_CHUNK_BYTES)),
        )
        .route(
            "/streams/{id}/finish",
            axum::routing::post(stream_api::finish),
        )
        .route("/streams/{id}/scene", get(stream_api::scene))
        .route("/streams/{id}/result", get(stream_api::result))
        .route("/graphs", get(api::list_graphs))
        .route(
            "/graphs/{graph_id}",
            get(api::get_graph).put(api::put_graph),
        )
        .route("/graphs/{graph_id}/routes", axum::routing::post(api::route))
        .route(
            "/scans",
            get(scan_api::list)
                .post(scan_api::upload)
                .layer(DefaultBodyLimit::max(32 * 1024 * 1024)),
        )
        .route("/scans/{scan_id}", get(scan_api::original))
        .route("/scans/{scan_id}/scene", get(scan_api::default_scene))
        .route(
            "/scans/{scan_id}/process",
            axum::routing::post(scan_api::process),
        )
        .route("/scans/{scan_id}/preview", get(scan_api::preview))
        .fallback(api::not_found)
        .method_not_allowed_fallback(api::method_not_allowed)
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
