#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingProcessAction {
    EnqueueOffer,
    EnqueueWelcome,
    EnqueueContactConfirmation,
    CommitContact,
    StartEndpointExchange,
    CreateConversation,
    NotifyUser,
    ScheduleRecovery,
}
