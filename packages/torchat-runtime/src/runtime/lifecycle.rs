use super::*;

impl<S, T, C> ClientRuntime<S, T, C>
where
    S: RuntimeStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    pub fn bootstrap_runtime(&mut self) -> RuntimeResult<bool> {
        if !self.session.mark_bootstrap_emitted() {
            return Ok(false);
        }
        self.session.push_event(RuntimeEvent::RuntimeReady {
            protocol: torchat_core::PROTOCOL_VERSION,
        });
        if let Some(profile) = self.storage.profile()? {
            self.session
                .push_event(RuntimeEvent::ProfileReady { profile });
        }
        Ok(true)
    }

    pub fn report_tor_status(&mut self, status: crate::RuntimeTorStatus) {
        self.session.publish_tor_status(status);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn report_transport_status(
        &mut self,
        component: crate::TransportComponent,
        state: crate::TransportProbeState,
        detail: impl Into<String>,
        progress: Option<i32>,
        latency_ms: Option<u64>,
        retry_attempt: u32,
        retry_in_ms: Option<u64>,
        generation: u64,
        endpoint: Option<String>,
        updated_at: i64,
    ) {
        self.session
            .push_event(crate::RuntimeEvent::TransportStatusChanged {
                component,
                state,
                detail: detail.into(),
                progress,
                latency_ms,
                retry_attempt,
                retry_in_ms,
                generation,
                endpoint,
                updated_at,
            });
    }

    pub fn apply_remote_profile(
        &mut self,
        profile: RuntimeProfile,
    ) -> RuntimeResult<RuntimeProfile> {
        self.storage.put_profile(profile.clone())?;
        self.session.push_event(RuntimeEvent::ProfileReady {
            profile: profile.clone(),
        });
        Ok(profile)
    }

    pub fn report_runtime_error(&mut self, message: String) {
        self.session.publish_runtime_error(message);
    }

    pub fn report_runtime_log(&mut self, message: String) {
        self.session.publish_runtime_log(message);
    }

    pub fn connect(&mut self) -> RuntimeResult<bool> {
        let status = self.transport.connect()?;
        self.emit_tor_status(status);
        Ok(true)
    }
}
