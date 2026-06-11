use clap::Parser;
use color_eyre::eyre::Result;
use rbx_studio_server::*;
use rmcp::ServiceExt;
use std::io;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing_subscriber::{self, EnvFilter};
mod error;
mod install;
mod rbx_studio_server;

/// Simple MCP proxy for Roblox Studio
/// Run without arguments to install the plugin
#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Args {
    /// Run as MCP server on stdio
    #[arg(short, long)]
    stdio: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(io::stderr)
        .with_target(false)
        .with_thread_ids(true)
        .init();

    let args = Args::parse();
    if !args.stdio {
        return install::install().await;
    }

    tracing::debug!("Debug MCP tracing enabled");

    let server_state = Arc::new(Mutex::new(AppState::new()));

    let (close_tx, close_rx) = tokio::sync::watch::channel(false);

    let server_handle = tokio::spawn(serve_http(Arc::clone(&server_state), close_rx));

    // Create an instance of our counter router
    let service = RBXStudioServer::new(Arc::clone(&server_state))
        .serve(rmcp::transport::stdio())
        .await
        .inspect_err(|e| {
            tracing::error!("serving error: {:?}", e);
        })?;
    service.waiting().await?;

    close_tx.send(true).ok();
    tracing::info!("Waiting for web server to gracefully shutdown");
    server_handle.await.ok();
    tracing::info!("Bye!");
    Ok(())
}
