//! Pure client-domain vocabulary shared by runtime and application adapters.

/// User-visible actions that may be applied to a pairing state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingAction {
    Accept,
    Reject,
    Complete,
    Expire,
    Archive,
    Cancel,
}

/// Durable lifecycle state for a pairing invitation.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum InviteState {
    #[default]
    Pending,
    Accepted,
    Rejected,
    Completed,
    Expired,
    Archived,
    Cancelled,
}

impl InviteState {
    pub fn is_pending(&self) -> bool {
        matches!(self, Self::Pending)
    }
    pub fn is_accepted(&self) -> bool {
        matches!(self, Self::Accepted)
    }
    pub fn is_outstanding(&self) -> bool {
        self.is_pending() || self.is_accepted()
    }
    pub fn can_archive(&self) -> bool {
        matches!(
            self,
            Self::Accepted | Self::Rejected | Self::Completed | Self::Expired | Self::Cancelled
        )
    }
    pub fn is_archived(&self) -> bool {
        matches!(self, Self::Archived)
    }
    pub fn is_rejected(&self) -> bool {
        matches!(self, Self::Rejected)
    }
    pub fn is_completed(&self) -> bool {
        matches!(self, Self::Completed)
    }
    pub fn is_cancelled(&self) -> bool {
        matches!(self, Self::Cancelled)
    }
    pub fn is_expired(&self) -> bool {
        matches!(self, Self::Expired)
    }
    pub fn is_terminal(&self) -> bool {
        !self.is_outstanding()
    }
}

/// Actions currently available for an invitation in a given projection.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PairingAvailableAction {
    Accept,
    Reject,
    Archive,
    Cancel,
}

/// Local relationship projection for an invitation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingRelationshipState {
    Candidate,
    AwaitingLocalApproval,
    AwaitingRemoteApproval,
    Finalizing,
    Active,
    Terminal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PairingSendKind {
    Offer,
    Rejection,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PairingPeerOutcome {
    OfferReceived,
    RejectionReceived,
    WelcomePrepared,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum VerificationState {
    Verified,
    Unverified,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PeerEndpointStatus {
    #[default]
    Missing,
    PendingExchange,
    Verified,
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CapabilityStatus {
    Missing,
    Pending,
    Active,
    Rotating,
    Revoked,
    Expired,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PeerConnectionStatus {
    #[default]
    Offline,
    Connecting,
    Authenticating,
    Connected,
    Backoff,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ContactTransportPolicy {
    #[default]
    PeerOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ConversationState {
    Pending,
    Verifying,
    Active,
    Offline,
    Failed,
}

impl ConversationState {
    pub fn is_pending(&self) -> bool {
        matches!(self, Self::Pending)
    }
    pub fn is_online(&self) -> bool {
        matches!(self, Self::Active)
    }
    pub fn is_offline(&self) -> bool {
        matches!(self, Self::Offline)
    }
    pub fn is_failed(&self) -> bool {
        matches!(self, Self::Failed)
    }
    pub fn can_send(&self) -> bool {
        matches!(self, Self::Active | Self::Offline)
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Verifying => "VERIFYING",
            Self::Active => "ACTIVE",
            Self::Offline => "OFFLINE",
            Self::Failed => "FAILED",
        }
    }
}

impl TryFrom<&str> for ConversationState {
    type Error = String;
    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value.trim().to_ascii_uppercase().as_str() {
            "PENDING" => Ok(Self::Pending),
            "VERIFYING" => Ok(Self::Verifying),
            "ACTIVE" => Ok(Self::Active),
            "OFFLINE" => Ok(Self::Offline),
            "FAILED" => Ok(Self::Failed),
            other => Err(format!("unknown conversation state: {other}")),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MessageState {
    Queued,
    Sending,
    Sent,
    Delivered,
    Read,
    Failed,
}

impl MessageState {
    pub fn is_queued(&self) -> bool {
        matches!(self, Self::Queued)
    }
    pub fn is_sending(&self) -> bool {
        matches!(self, Self::Sending)
    }
    pub fn is_sent(&self) -> bool {
        matches!(self, Self::Sent)
    }
    pub fn is_delivered(&self) -> bool {
        matches!(self, Self::Delivered | Self::Read)
    }
    pub fn is_failed(&self) -> bool {
        matches!(self, Self::Failed)
    }
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Delivered | Self::Read | Self::Failed)
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Queued => "QUEUED",
            Self::Sending => "SENDING",
            Self::Sent => "SENT",
            Self::Delivered => "DELIVERED",
            Self::Read => "READ",
            Self::Failed => "FAILED",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MessageTransportOutcome {
    Delivered,
    PeerPersisted,
    PeerDelivered,
    PeerUnavailable,
    PeerAuthenticationFailed,
    PeerRejected,
    RetryableFailure,
    PermanentFailure,
}

pub fn pairing_available_actions(
    state: InviteState,
    received: bool,
) -> Vec<PairingAvailableAction> {
    use InviteState::{Accepted, Archived, Pending};
    use PairingAvailableAction::{Accept, Archive, Cancel, Reject};

    if state == Archived {
        return Vec::new();
    }
    if received && state == Pending {
        return vec![Accept, Reject];
    }
    if !received && matches!(state, Pending | Accepted) {
        return vec![Cancel];
    }
    if state.can_archive() {
        return vec![Archive];
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_actions_are_stable_and_copyable() {
        let action = PairingAction::Accept;
        assert_eq!(action, PairingAction::Accept);
        assert_eq!(action as u8, 0);
    }

    #[test]
    fn available_actions_follow_pure_pairing_state_rules() {
        assert_eq!(
            pairing_available_actions(InviteState::Pending, true),
            vec![
                PairingAvailableAction::Accept,
                PairingAvailableAction::Reject
            ]
        );
        assert_eq!(
            pairing_available_actions(InviteState::Accepted, false),
            vec![PairingAvailableAction::Cancel]
        );
        assert_eq!(
            pairing_available_actions(InviteState::Completed, false),
            vec![PairingAvailableAction::Archive]
        );
        assert!(pairing_available_actions(InviteState::Archived, true).is_empty());
    }
}
