use std::{env, net::SocketAddr};

use inview_backend::{AppState, app};
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
    if let Ok(path) = env::var("INVIEW_SCAN_DIR") {
        let path = std::path::PathBuf::from(path);
        state.scans = inview_backend::store::ScanStore::open(&path)?;
        // Graphs are replaceable output, persisted next to the scans they were derived from.
        state.graphs = inview_backend::store::GraphStore::open(path.join("graphs"))?;
    }
    if let Ok(url) = env::var("INVIEW_DATABASE_URL") {
        if env::var("INVIEW_SCAN_DIR").is_err() {
            return Err(
                "INVIEW_SCAN_DIR is required with PostgreSQL so source scans survive restarts"
                    .into(),
            );
        }
        let require_timescale = env::var("INVIEW_REQUIRE_TIMESCALE").as_deref() == Ok("1");
        state.maps = Some(inview_backend::buildings::connect(&url, require_timescale).await?);
        tracing::info!("Building maps connected to PostgreSQL (Timescale when available)");
    } else {
        if env::var("INVIEW_REQUIRE_TIMESCALE").as_deref() == Ok("1") {
            return Err("INVIEW_REQUIRE_TIMESCALE=1 requires INVIEW_DATABASE_URL".into());
        }
        tracing::warn!("INVIEW_DATABASE_URL unset; building-map endpoints return 503");
    }
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
