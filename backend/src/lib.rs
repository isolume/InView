pub mod api;
pub mod error;
pub mod graph;
pub mod routing;
pub mod store;

use axum::{Router, extract::DefaultBodyLimit, routing::get};
use tower_http::trace::TraceLayer;

use store::GraphStore;

#[derive(Clone, Default)]
pub struct AppState {
    pub graphs: GraphStore,
}

pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(api::health))
        .route("/graphs", get(api::list_graphs))
        .route(
            "/graphs/{graph_id}",
            get(api::get_graph).put(api::put_graph),
        )
        .route("/graphs/{graph_id}/routes", axum::routing::post(api::route))
        .fallback(api::not_found)
        .method_not_allowed_fallback(api::method_not_allowed)
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
