use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use url::Url;
pub use torchat_storage::SecretBytes;

use crate::PlatformKind;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineConfig {
    pub database_path: PathBuf,
    pub database_key: SecretBytes,
    pub identity_private_key: SecretBytes,
    pub relay_onion_url: Url,
    pub initial_socks5_url: Option<Url>,
    pub log_directory: Option<PathBuf>,
    pub platform: PlatformKind,
}
