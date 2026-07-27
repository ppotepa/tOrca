use serde::{Deserialize, Serialize};
use torchat_core::relay::{RelayClientFrame, RelayServerFrame};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize)]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
    pub challenge: String,
}

#[allow(dead_code)]
#[derive(Clone, Debug, Deserialize)]
pub struct SessionResponse {
    pub installation_id: String,
    pub session_token: String,
    pub security_status: String,
}

#[allow(dead_code)]
#[derive(Clone, Debug, Deserialize)]
pub struct ProfileResponse {
    pub installation_id: String,
    pub nickname: Option<String>,
    pub public_key: String,
    pub fingerprint: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PairingCodeResponse {
    pub code: String,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PairingInboxItem {
    pub pairing_id: Uuid,
    pub sender: torchat_core::relay::ContactCard,
    pub capability: String,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct RegisterRequest {
    pub challenge_id: Uuid,
    pub public_key: String,
    pub proof: String,
}

pub type ClientFrame = RelayClientFrame;
pub type ServerFrame = RelayServerFrame;
