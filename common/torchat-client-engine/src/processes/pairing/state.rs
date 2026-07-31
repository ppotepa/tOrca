#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingProcessState {
    CodeSubmitted,
    RequestPending,
    OfferReceived,
    OfferPrepared,
    OfferQueued,
    OfferAcknowledged,
    WelcomeReceived,
    WelcomeCommitted,
    ContactConfirmationQueued,
    ContactCommitted,
    EndpointExchangePending,
    Completed,
    Rejected,
    Cancelled,
    Expired,
    Failed,
}

impl PairingProcessState {
    pub const fn terminal(self) -> bool {
        matches!(
            self,
            Self::Completed
                | Self::Rejected
                | Self::Cancelled
                | Self::Expired
                | Self::Failed
        )
    }
}
