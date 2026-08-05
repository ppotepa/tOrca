use torchat_runtime::{RuntimeError, RuntimeResult};

pub(super) const IDENTITY_KEY: &str = "runtime_identity_v1";
pub(super) const PROFILE_KEY: &str = "runtime_profile_v1";
pub(super) const PAIRING_CODE_KEY: &str = "pairing_code_v1";

pub(super) fn encode<T: serde::Serialize>(value: &T) -> RuntimeResult<Vec<u8>> {
    serde_json::to_vec(value).map_err(|error| RuntimeError::Storage(error.to_string()))
}

pub(super) fn decode<T: serde::de::DeserializeOwned>(value: &[u8]) -> RuntimeResult<T> {
    serde_json::from_slice(value).map_err(|error| RuntimeError::Storage(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::{decode, encode};

    #[test]
    fn settings_payload_round_trips() {
        let payload = encode(&vec!["profile", "v1"]).unwrap();
        assert_eq!(
            decode::<Vec<String>>(&payload).unwrap(),
            vec!["profile", "v1"]
        );
    }
}
