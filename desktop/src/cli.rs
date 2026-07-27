use clap::Parser;
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "torchat-desktop", version, about = "TorChat desktop client")]
pub struct Cli {
    /// Exact v3 onion server URL. TorChat has no direct/LAN fallback.
    #[arg(long, env = "TORCHAT_SERVER_URL")]
    pub server_url: String,

    /// SOCKS5 proxy, normally a local Tor daemon, e.g. socks5h://127.0.0.1:9050.
    #[arg(long, env = "TORCHAT_SOCKS5_PROXY")]
    pub socks5_proxy: Option<String>,

    /// Managed Tor executable. When set, desktop owns the Tor process and
    /// ignores --socks5-proxy.
    #[arg(long, env = "TORCHAT_TOR_BINARY")]
    pub tor_binary: Option<PathBuf>,

    /// Storage used by the managed Tor process.
    #[arg(long, env = "TORCHAT_TOR_DATA_DIR")]
    pub tor_data_dir: Option<PathBuf>,

    /// Override the identity storage location.
    #[arg(long, env = "TORCHAT_IDENTITY_FILE")]
    pub identity_file: Option<PathBuf>,

    /// Publish this nickname for paired contacts after bootstrap.
    #[arg(long, env = "TORCHAT_NICKNAME")]
    pub nickname: Option<String>,

    /// Load a checked-in development MLS snapshot (never use in production).
    #[arg(long, requires = "dev_peer")]
    pub dev_fixture: Option<PathBuf>,

    /// Installation id of the Android peer used with --dev-fixture.
    #[arg(long, requires = "dev_fixture")]
    pub dev_peer: Option<String>,

    /// Public nickname for the fixture peer.
    #[arg(long, default_value = "Alice")]
    pub dev_peer_nickname: String,

    /// Public identity file for the fixture peer; used to derive its real
    /// installation ID instead of relying on stale hardcoded IDs.
    #[arg(long)]
    pub dev_peer_identity_file: Option<PathBuf>,

    /// Start the complete runtime without a window and exit after the relay is
    /// connected. Used by deployment smoke tests.
    #[arg(long, default_value_t = false)]
    pub headless_smoke: bool,

    /// Connect without a window, send one encrypted development message and
    /// exit after the Android peer confirms delivery.
    #[arg(long)]
    pub headless_send: Option<String>,

    /// Run the runtime as a JSON-lines sidecar for the Flutter client.
    #[arg(long, default_value_t = false)]
    pub stdio_runtime: bool,
}
