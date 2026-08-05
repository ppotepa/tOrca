use torchat_runtime::{InviteCode, PairingItem, RuntimeError, RuntimeResult};

use crate::{
    EngineRelay,
    relay::{RelayDeferredControl, RelayEvent},
};

#[derive(Default)]
pub(crate) struct RelayEffectPlaceholder {
    deferred: RelayDeferredControl,
}

impl EngineRelay for RelayEffectPlaceholder {
    fn can_start_effect(&self) -> bool {
        false
    }

    fn take_deferred_control(&mut self) -> RelayDeferredControl {
        std::mem::take(&mut self.deferred)
    }

    fn set_socks5_url(&mut self, socks5_url: Option<String>) {
        self.deferred.socks5_url = Some(socks5_url);
    }

    fn invalidate_session(&mut self) {
        self.deferred.invalidate_session = true;
    }

    fn shutdown(&mut self) {}

    fn ensure_session(&mut self) -> RuntimeResult<()> {
        busy()
    }

    fn send_envelope(
        &mut self,
        _message_id: uuid::Uuid,
        _recipient: &str,
        _ciphertext: &str,
    ) -> RuntimeResult<()> {
        busy()
    }

    fn poll_event(&mut self) -> Option<RelayEvent> {
        None
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        busy()
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        busy()
    }

    fn submit_pairing_code_with_offer(
        &mut self,
        _code: &str,
        _pairing_id: uuid::Uuid,
        _offer: String,
    ) -> RuntimeResult<PairingItem> {
        busy()
    }

    fn cancel_pairing(&mut self, _pairing_id: &str) -> RuntimeResult<()> {
        busy()
    }
}

fn busy<T>() -> RuntimeResult<T> {
    Err(RuntimeError::Unavailable(
        "rendezvous effect is already in progress".to_owned(),
    ))
}
