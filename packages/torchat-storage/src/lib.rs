pub mod error;
pub mod storage;

pub use error::{EngineError, EngineResult};
pub use storage::*;

use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

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
