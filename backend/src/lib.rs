pub mod alignment;
pub mod api;
pub mod auth;
pub mod building_nav;
pub mod buildings;
pub mod capture;
pub mod display_mesh;
pub mod error;
pub mod geometry;
pub mod graph;
pub mod map_frame;
pub mod model_meshes;
pub mod product_api;
pub mod product_store;
pub mod raw_lidar;
pub mod recognition_service;
pub mod recognized_objects;
pub mod route_api;
pub mod routing;
pub mod scan_api;
pub mod scan_package;
pub mod scene;
pub mod store;
pub mod stream_api;
mod stream_evidence;
pub mod stream_scan;
pub mod streaming;
pub mod studio;

use axum::{
    Router,
    extract::DefaultBodyLimit,
    middleware,
    routing::{get, post},
};
use sqlx::PgPool;
use std::sync::Arc;
use store::{GraphStore, ScanStore};
use tower_http::trace::TraceLayer;

#[derive(Clone)]
pub struct AppState {
    /// Processing output and candidate graphs. Never the public routing catalog.
    pub graphs: GraphStore,
    /// Explicitly reviewed snapshots, published through an administrator account.
    pub published_graphs: GraphStore,
    pub scans: ScanStore,
    pub streams: streaming::StreamStore,
    pub product: product_store::ProductStore,
    pub maps: Option<PgPool>,
    pub api_token: Option<Arc<str>>,
    pub processing_requests: Arc<tokio::sync::Semaphore>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            graphs: GraphStore::default(),
            published_graphs: GraphStore::default(),
            scans: ScanStore::default(),
            streams: streaming::StreamStore::default(),
            product: product_store::ProductStore::default(),
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
    // Processing credentials do not replace account sessions or gate public map browsing.
    let processing = Router::new()
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
        .route(
            "/api/buildings/{building_id}/connectors",
            get(buildings::connectors)
                .post(buildings::add_connector)
                .layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route(
            "/api/buildings/{building_id}/routes",
            post(route_api::building_routes).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route(
            "/api/buildings/{building_id}/levels",
            get(route_api::building_levels),
        )
        .route("/graphs", get(api::list_graphs))
        .route("/graphs/{graph_id}", axum::routing::put(api::put_graph))
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
        .route("/scans/{scan_id}/camera-track", get(scan_api::camera_track))
        .route("/scans/{scan_id}/manifest", get(scan_api::manifest))
        .route(
            "/scans/{scan_id}/routes",
            post(route_api::scan_routes).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route("/scans/{scan_id}/levels", get(route_api::scan_levels))
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
        .route_layer(middleware::from_fn_with_state(
            state.api_token.clone(),
            auth::authorize,
        ));
    Router::new()
        .route("/", get(studio::page))
        .route("/studio", get(studio::page))
        .route("/studio/assets/{name}", get(studio::asset))
        .route("/scans/{scan_id}/preview", get(scan_api::preview))
        .route("/graphs/{graph_id}", get(api::get_graph))
        .route("/graphs/{graph_id}/routes", post(api::route))
        .route("/api/admin/graphs/{graph_id}", get(api::review_graph))
        .route(
            "/api/admin/graphs/{graph_id}/publish",
            post(api::publish_graph),
        )
        .route("/admin", get(product_api::admin_workspace))
        .route(
            "/api/accounts/register",
            axum::routing::post(product_api::register).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route(
            "/api/accounts/login",
            axum::routing::post(product_api::login).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route("/api/accounts/me", get(product_api::me))
        .route(
            "/api/accounts/logout",
            axum::routing::post(product_api::logout),
        )
        .route(
            "/api/submissions",
            get(product_api::list).post(product_api::submit),
        )
        .route("/api/submissions/{id}", get(product_api::get))
        .route(
            "/api/submissions/{id}/resubmit",
            axum::routing::post(product_api::resubmit),
        )
        .route("/api/admin/submissions", get(product_api::admin_list))
        .route(
            "/api/admin/submissions/{id}",
            axum::routing::patch(product_api::edit),
        )
        .route(
            "/api/admin/submissions/{id}/publish",
            axum::routing::post(product_api::publish),
        )
        .route("/api/venues/{venue}/maps", get(product_api::maps))
        .route(
            "/api/venues/{venue}/maps/{floor}/versions/{version}",
            get(product_api::version),
        )
        .merge(processing)
        .fallback(api::not_found)
        .method_not_allowed_fallback(api::method_not_allowed)
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn(product_api::protect_response))
        .with_state(state)
}
