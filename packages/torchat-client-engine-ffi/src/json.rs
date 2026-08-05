use serde::{Serialize, de::DeserializeOwned};
use torchat_client_engine::{EngineError, EngineResult};

pub fn decode<T: DeserializeOwned>(value: &[u8]) -> EngineResult<T> {
    serde_json::from_slice(value).map_err(EngineError::from)
}

pub fn encode<T: Serialize>(value: &T) -> EngineResult<String> {
    serde_json::to_string(value).map_err(EngineError::from)
}
