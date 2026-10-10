use std::{env, net::SocketAddr};

use inview_backend::{
    AppState, app, product_store::ProductStore, recognition_service::RecognitionConfig,
    streaming::StreamStore,
};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("inview_backend=info,tower_http=info")),
        )
        .init();

    let address: SocketAddr = env::var("INVIEW_BIND")
        .unwrap_or_else(|_| "127.0.0.1:3000".to_owned())
        .parse()?;
    let mut state = AppState::default();
    if let Ok(token) = env::var("INVIEW_API_TOKEN") {
        if token.len() < 32 || !token.is_ascii() || token.bytes().any(|b| b.is_ascii_whitespace()) {
            return Err(
                "INVIEW_API_TOKEN must be at least 32 ASCII non-whitespace characters".into(),
            );
        }
        state.api_token = Some(token.into());
    }
    if !address.ip().is_loopback() && state.api_token.is_none() {
        return Err(
            "Non-loopback binds require INVIEW_API_TOKEN and HTTPS at the reverse proxy".into(),
        );
    }
    let scan_path = std::path::PathBuf::from(
        env::var("INVIEW_SCAN_DIR").unwrap_or_else(|_| "data/scans".into()),
    );
    state.scans = inview_backend::store::ScanStore::open(&scan_path)?;
    state.graphs = inview_backend::store::GraphStore::open(scan_path.join("graphs"))?;
    state.published_graphs =
        inview_backend::store::GraphStore::open(scan_path.join("published-graphs"))?;
    if let Ok(url) = env::var("INVIEW_DATABASE_URL") {
        let require_timescale = env::var("INVIEW_REQUIRE_TIMESCALE").as_deref() == Ok("1");
        state.maps = Some(inview_backend::buildings::connect(&url, require_timescale).await?);
        tracing::info!("Building maps connected to PostgreSQL");
    } else if env::var("INVIEW_REQUIRE_TIMESCALE").as_deref() == Ok("1") {
        return Err("INVIEW_REQUIRE_TIMESCALE=1 requires INVIEW_DATABASE_URL".into());
    }
    let stream_path = env::var("INVIEW_STREAM_DIR").unwrap_or_else(|_| "data/streams".to_owned());
    let mut streams = StreamStore::open(stream_path)
        .map_err(|error| format!("Cannot open streaming scan store: {error:?}"))?;
    match RecognitionConfig::from_environment()? {
        Some(config) => {
            streams = streams
                .with_recognition(config)
                .map_err(|error| format!("Cannot start furniture recognition: {error:?}"))?;
            tracing::info!("Local furniture recognition enabled");
        }
        None => {
            tracing::warn!("Furniture recognition disabled; run recognition/setup.sh to enable it")
        }
    }
    let product_path = env::var("INVIEW_PRODUCT_DIR").unwrap_or_else(|_| "data/product".into());
    let product = ProductStore::open(product_path)?;
    match (
        env::var("INVIEW_ADMIN_EMAIL").ok(),
        env::var("INVIEW_ADMIN_PASSWORD").ok(),
    ) {
        (Some(email), Some(password)) => product.bootstrap_admin(&email, &password).map_err(
            |_| "Administrator bootstrap failed. Check the dedicated account credentials.",
        )?,
        (None, None) => {}
        _ => return Err(
            "Set both INVIEW_ADMIN_EMAIL and INVIEW_ADMIN_PASSWORD to bootstrap an administrator."
                .into(),
        ),
    }
    // Update this configured state; reconstructing a default state here would disable auth
    // and discard every store opened above.
    state.streams = streams;
    state.product = product;
    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!(address = %listener.local_addr()?, "InView backend listening");
    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

async fn shutdown() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        tracing::error!(%error, "Could not listen for shutdown");
    }
}
