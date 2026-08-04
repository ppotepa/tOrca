use crate::{InviteCode, PairingItem, RuntimeResult, RuntimeTorStatus};

pub trait RuntimeTransport {
    fn connect(&mut self) -> RuntimeResult<RuntimeTorStatus>;
    fn status(&self) -> RuntimeTorStatus;
    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode>;
    fn submit_pairing_code(&mut self, code: &str) -> RuntimeResult<PairingItem>;
    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>>;
}
