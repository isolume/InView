pub mod alignment;
pub mod api;
pub mod auth;
pub mod buildings;
pub mod capture;
pub mod display_mesh;
pub mod error;
pub mod geometry;
pub mod graph;
pub mod map_frame;
pub mod model_meshes;
pub mod raw_lidar;
pub mod recognition_service;
pub mod recognized_objects;
pub mod routing;
pub mod scan_api;
pub mod scan_package;
pub mod scene;
pub mod store;
pub mod stream_api;
pub mod stream_scan;
pub mod streaming;
pub mod studio;

use axum::{
    Router,
    extract::DefaultBodyLimit,
    middleware,
    routing::{get, post},
};
use std::sync::Arc;
use tower_http::trace::TraceLayer;

use sqlx::PgPool;
use store::{GraphStore, ScanStore};

#[derive(Clone)]
pub struct AppState {
    pub graphs: GraphStore,
    pub scans: ScanStore,
    pub streams: streaming::StreamStore,
    pub maps: Option<PgPool>,
    pub api_token: Option<Arc<str>>,
    pub processing_requests: Arc<tokio::sync::Semaphore>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            graphs: GraphStore::default(),
            scans: ScanStore::default(),
            streams: streaming::StreamStore::default(),
            maps: None,
            api_token: None,
            processing_requests: Arc::new(tokio::sync::Semaphore::new(4)),
        }
    }
}

impl AppState {
    pub(crate) fn processing_permit(
        &self,
    ) -> Result<tokio::sync::OwnedSemaphorePermit, error::ApiError> {
        self.processing_requests
            .clone()
            .try_acquire_owned()
            .map_err(|_| {
                error::ApiError::new(
                    axum::http::StatusCode::SERVICE_UNAVAILABLE,
                    "processing_busy",
                    "Scans are already processing. Retry shortly.",
                )
            })
    }
}

pub fn app(state: AppState) -> Router {
    let api_token = state.api_token.clone();
    Router::new()
        .route("/", get(studio::page))
        .route("/studio", get(studio::page))
        .route("/studio/assets/{name}", get(studio::asset))
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
        .route(
            "/streams/{id}/assets/{name}",
            axum::routing::put(stream_api::asset)
                .layer(DefaultBodyLimit::max(streaming::MAX_ASSET_BYTES)),
        )
        .route(
            "/api/buildings",
            get(buildings::list).post(buildings::create),
        )
        .route("/api/buildings/{building_id}", get(buildings::get))
        .route(
            "/api/buildings/{building_id}/alignments",
            post(buildings::align),
        )
        .route(
            "/api/buildings/{building_id}/observations",
            get(buildings::observations),
        )
        .route(
            "/api/buildings/{building_id}/overview",
            get(buildings::overview),
        )
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
        .route(
            "/scan-packages",
            post(scan_api::upload_package)
                .layer(DefaultBodyLimit::max(scan_package::MAX_PACKAGE_BYTES)),
        )
        .route("/scans/{scan_id}", get(scan_api::original))
        .route("/scans/{scan_id}/scene", get(scan_api::default_scene))
        .route(
            "/scans/{scan_id}/process",
            axum::routing::post(scan_api::process),
        )
        .route("/scans/{scan_id}/preview", get(scan_api::preview))
        .route("/scans/{scan_id}/camera-track", get(scan_api::camera_track))
        .route("/scans/{scan_id}/manifest", get(scan_api::manifest))
        .route("/scans/{scan_id}/assets/{filename}", get(scan_api::asset))
        .route(
            "/scans/{scan_id}/analysis",
            get(scan_api::analysis)
                .put(scan_api::put_analysis)
                .layer(DefaultBodyLimit::max(16 * 1024 * 1024)),
        )
        .route("/scans/{scan_id}/raw-preview", get(raw_lidar::preview))
        .route("/scans/{scan_id}/native-mesh", get(raw_lidar::native_mesh))
        .route(
            "/scans/{scan_id}/color/{filename}",
            get(raw_lidar::color_asset),
        )
        .fallback(api::not_found)
        .method_not_allowed_fallback(api::method_not_allowed)
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn_with_state(api_token, auth::authorize))
        .with_state(state)
}
