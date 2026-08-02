use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use url::Url;
use zeroize::Zeroize;

use crate::command::PlatformKind;

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

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SecretBytes(#[serde(with = "serde_bytes")] pub Vec<u8>);

impl SecretBytes {
    pub fn expose(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl std::fmt::Debug for SecretBytes {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SecretBytes([redacted])")
    }
}
