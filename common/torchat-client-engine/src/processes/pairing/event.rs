#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingProcessEvent {
    RemoteRequestObserved,
    OfferReceived,
    OfferPrepared,
    OfferQueued,
    OfferAcknowledged,
    WelcomeReceived,
    WelcomeValidated,
    ContactConfirmationQueued,
    ContactCommitted,
    ConfirmationDelivered,
    EndpointVerified,
    RejectRequested,
    CancelRequested,
    Expired,
    FailureObserved { reason: String },
}
