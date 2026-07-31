pub mod pairing;

pub use pairing::{
    InvalidPairingTransition, PairingProcess, PairingProcessAction, PairingProcessEvent,
    PairingProcessRepository, PairingProcessState,
};

#[cfg(test)]
mod tests {
    use super::{PairingProcess, PairingProcessAction, PairingProcessEvent, PairingProcessState};

    #[test]
    fn pairing_process_exports_are_available_from_module_root() {
        let mut process = PairingProcess::new("pairing-contract", 0);
        let actions = process
            .apply(PairingProcessEvent::RemoteRequestObserved, 1)
            .expect("transition succeeds");

        assert_eq!(process.state, PairingProcessState::RequestPending);
        assert_eq!(actions, vec![PairingProcessAction::ScheduleRecovery]);
    }
}
