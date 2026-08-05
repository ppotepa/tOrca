pub(crate) struct DeferredCommandContext {
    pub request_id: String,
    pub command_id: Option<String>,
    pub command_descriptor: String,
}

pub(crate) enum RelayEffectOperation {
    RefreshPairingCode,
    SubmitPairingCode {
        code: String,
        pairing_id: uuid::Uuid,
        offer: String,
    },
    CancelPairing {
        pairing_id: String,
    },
}
