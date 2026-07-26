use serde::{Deserialize, Serialize};
use torchat_core::relay::{RelayClientFrame, RelayServerFrame};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize)]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
    pub challenge: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SessionResponse {
    pub installation_id: String,
    pub session_token: String,
    pub security_status: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ProfileResponse {
    pub installation_id: String,
    pub nickname: Option<String>,
    pub public_key: String,
    pub fingerprint: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DirectoryEntry {
    pub installation_id: String,
    pub nickname: String,
    pub public_key: String,
    pub fingerprint: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct RegisterRequest {
    pub challenge_id: Uuid,
    pub public_key: String,
    pub proof: String,
}

pub type ClientFrame = RelayClientFrame;
pub type ServerFrame = RelayServerFrame;
