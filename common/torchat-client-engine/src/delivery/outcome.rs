#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeliveryOutcome {
    PeerPersisted,
    PeerDelivered,
    RelayForwarded,
    Delivered,
    RecipientOffline,
    AuthenticationFailed,
    RetryableFailure { code: String },
    PermanentFailure { code: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryOutcomeClass {
    Progress,
    Delivered,
    Retryable,
    Permanent,
}

impl DeliveryOutcome {
    pub const fn class(&self) -> DeliveryOutcomeClass {
        match self {
            Self::PeerPersisted | Self::RelayForwarded => DeliveryOutcomeClass::Progress,
            Self::PeerDelivered | Self::Delivered => DeliveryOutcomeClass::Delivered,
            Self::RecipientOffline | Self::RetryableFailure { .. } => {
                DeliveryOutcomeClass::Retryable
            }
            Self::AuthenticationFailed | Self::PermanentFailure { .. } => {
                DeliveryOutcomeClass::Permanent
            }
        }
    }
}
