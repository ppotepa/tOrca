use serde::{Deserialize, Serialize};
use torchat_client_runtime::InviteState;
use torchat_core::relay::{RelayClientFrame, RelayServerFrame};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize)]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
    pub challenge: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SessionResponse {
    pub session_token: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PairingCodeResponse {
    pub code: String,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PairingRequestResponse {
    pub pairing_id: Uuid,
    pub expires_at: i64,
    #[serde(default)]
    pub state: InviteState,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PairingInboxItem {
    pub pairing_id: Uuid,
    pub sender: torchat_core::relay::ContactCard,
    pub capability: String,
    pub expires_at: i64,
    #[serde(default)]
    pub state: InviteState,
    #[serde(default)]
    pub offer_invite_id: Option<String>,
    #[serde(default)]
    pub offer_payload: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RegisterRequest {
    pub challenge_id: Uuid,
    pub public_key: String,
    pub proof: String,
}

pub type ClientFrame = RelayClientFrame;
pub type ServerFrame = RelayServerFrame;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_outbox_response_defaults_legacy_state_to_pending() {
        let value: PairingRequestResponse = serde_json::from_str(
            r#"{"pairing_id":"00000000-0000-0000-0000-000000000001","expires_at":1}"#,
        )
        .unwrap();

        assert_eq!(value.state, InviteState::Pending);
    }

    #[test]
    fn pairing_outbox_response_preserves_terminal_state() {
        let value: PairingRequestResponse = serde_json::from_str(
            r#"{"pairing_id":"00000000-0000-0000-0000-000000000001","expires_at":1,"state":"CANCELLED"}"#,
        )
        .unwrap();

        assert_eq!(value.state, InviteState::Cancelled);
    }
}
