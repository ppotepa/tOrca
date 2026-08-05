#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineInputSource {
    ClientApi,
    Ffi,
    Relay,
    Peer,
    Platform,
    Scheduler,
    EffectWorker,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineInputKind {
    Command,
    PeerEvent,
    RelayEvent,
    PlatformFact,
    TimerElapsed,
    EffectOutcome,
    ShutdownRequested,
}
