use std::{env, net::SocketAddr};

use inview_backend::{AppState, app, streaming::StreamStore};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("inview_backend=info,tower_http=info")),
        )
        .init();

    let address: SocketAddr = env::var("INVIEW_BIND")
        .unwrap_or_else(|_| "127.0.0.1:3000".to_owned())
        .parse()?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    let stream_path = env::var("INVIEW_STREAM_DIR").unwrap_or_else(|_| "data/streams".to_owned());
    let streams = StreamStore::open(stream_path)
        .map_err(|error| format!("Cannot open streaming scan store: {error:?}"))?;
    let state = AppState {
        streams,
        ..AppState::default()
    };
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
