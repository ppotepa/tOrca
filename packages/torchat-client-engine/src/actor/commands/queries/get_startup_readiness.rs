use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_startup_readiness(&mut self) -> CommandHandlerResult {
        Ok((
            json_response(StartupReadinessSnapshot {
                engine_ready: true,
                local_data_ready: true,
                tor_ready: self.socks5_url.is_some(),
                peer_listener_ready: self.peer_transport.is_some(),
                onion_service_ready: self.local_peer_endpoint.is_some(),
                generation: self.connection_generation,
                detail: self.tor_status.detail.clone(),
            })?,
            Vec::new(),
            None,
        ))
    }
}
