#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineTimerKind {
    RelayPoll,
    PeerProbeRound,
    RetryDue,
}
