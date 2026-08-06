use super::*;

impl ClientEngineActor {
    pub(super) fn apply_platform_fact(
        &mut self,
        fact: PlatformFact,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        match fact {
            PlatformFact::TorStatus {
                phase,
                progress,
                detail,
            } => {
                let (connection_state, runtime_phase, label) = match phase {
                    crate::TorPhase::Starting => (
                        ConnectionState::WaitingForTor,
                        RuntimeStatusPhase::Starting,
                        "tor starting",
                    ),
                    crate::TorPhase::Bootstrapping => (
                        ConnectionState::WaitingForTor,
                        RuntimeStatusPhase::Bootstrapping,
                        "tor bootstrapping",
                    ),
                    crate::TorPhase::Ready => {
                        let state = match self.connection_state {
                            ConnectionState::Connected
                            | ConnectionState::Connecting
                            | ConnectionState::Authenticating
                            | ConnectionState::WaitingForReady
                            | ConnectionState::Backoff { .. } => self.connection_state.clone(),
                            _ => ConnectionState::Disconnected,
                        };
                        let phase = runtime_phase_for_tor_ready(&state);
                        (state, phase, "tor ready")
                    }
                    crate::TorPhase::Failed => {
                        self.advance_connection_generation();
                        self.socks5_url = None;
                        self.relay.set_socks5_url(None);
                        self.requeue_after_disconnect()?;
                        (
                            ConnectionState::Stopped,
                            RuntimeStatusPhase::Error,
                            "tor failed",
                        )
                    }
                };
                self.connection_state = connection_state;
                self.tor_status = RuntimeTorStatus {
                    phase: runtime_phase,
                    label: label.to_owned(),
                    detail,
                    progress: Some(i32::from(progress)),
                    latency_ms: None,
                    retry_attempt: 0,
                };
                let status = self.tor_status.clone();
                let (_, mut runtime_events) = self.with_runtime(|runtime| {
                    runtime.report_tor_status(status);
                    Ok(())
                })?;
                runtime_events.push(transport_status_event(
                    torchat_runtime::TransportComponent::Engine,
                    relay_probe_state(&self.tor_status.phase),
                    self.tor_status.detail.clone(),
                    self.tor_status.progress,
                    self.tor_status.latency_ms,
                    self.tor_status.retry_attempt,
                    None,
                    self.connection_generation,
                    None,
                    self.clock.now_ms(),
                ));
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointAvailable { socks5_url } => {
                let endpoint_changed = self.socks5_url.as_deref() != Some(socks5_url.as_str());
                if endpoint_changed {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.socks5_url = Some(socks5_url);
                    self.relay.set_socks5_url(self.socks5_url.clone());
                    self.connection_state = ConnectionState::Disconnected;
                }
                if self.tor_status.phase == RuntimeStatusPhase::Starting
                    || self.tor_status.phase == RuntimeStatusPhase::Offline
                {
                    self.tor_status.phase = RuntimeStatusPhase::Bootstrapping;
                    self.tor_status.label = "tor endpoint available".to_owned();
                    self.tor_status.detail = "SOCKS endpoint available".to_owned();
                    self.tor_status.progress = self.tor_status.progress.or(Some(0));
                }
                let status = self.tor_status.clone();
                let (_, mut runtime_events) = self.with_runtime(|runtime| {
                    runtime.report_tor_status(status);
                    Ok(())
                })?;
                runtime_events.push(transport_status_event(
                    torchat_runtime::TransportComponent::Engine,
                    relay_probe_state(&self.tor_status.phase),
                    self.tor_status.detail.clone(),
                    self.tor_status.progress,
                    self.tor_status.latency_ms,
                    self.tor_status.retry_attempt,
                    None,
                    self.connection_generation,
                    self.socks5_url.clone(),
                    self.clock.now_ms(),
                ));
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointLost { reason } => {
                self.advance_connection_generation();
                self.socks5_url = None;
                self.relay.set_socks5_url(None);
                self.requeue_after_disconnect()?;
                self.connection_state = ConnectionState::WaitingForTor;
                self.tor_status.label = "tor unavailable".to_owned();
                self.tor_status.detail = reason;
                self.tor_status.phase = RuntimeStatusPhase::Offline;
                self.tor_status.progress = None;
                let status = self.tor_status.clone();
                let (_, mut runtime_events) = self.with_runtime(|runtime| {
                    runtime.report_tor_status(status);
                    Ok(())
                })?;
                runtime_events.push(transport_status_event(
                    torchat_runtime::TransportComponent::Engine,
                    torchat_runtime::TransportProbeState::Offline,
                    self.tor_status.detail.clone(),
                    None,
                    None,
                    self.tor_status.retry_attempt,
                    None,
                    self.connection_generation,
                    None,
                    self.clock.now_ms(),
                ));
                Ok(runtime_events)
            }
            PlatformFact::OnionServiceAvailable {
                onion_address,
                virtual_port,
                generation,
            } => {
                if generation != self.expected_onion_generation {
                    return Err(EngineError::InvalidCommand(
                        "stale onion service generation".to_owned(),
                    ));
                }
                if virtual_port != PEER_VIRTUAL_PORT {
                    return Err(EngineError::InvalidCommand(
                        "unsupported onion service virtual port".to_owned(),
                    ));
                }
                let sequence = self
                    .local_peer_endpoint
                    .as_ref()
                    .map(|endpoint| {
                        if endpoint.onion_address.eq_ignore_ascii_case(&onion_address) {
                            endpoint.sequence
                        } else {
                            endpoint.sequence.saturating_add(1)
                        }
                    })
                    .unwrap_or(1);
                let previous_endpoint = self.local_peer_endpoint.clone();
                let endpoint = PeerEndpointBundle::new(
                    &self.identity,
                    onion_address,
                    sequence,
                    self.clock.now_ms() / 1_000,
                    None,
                );
                endpoint
                    .validate(self.clock.now_ms() / 1_000)
                    .map_err(EngineError::InvalidCommand)?;
                self.database
                    .put_local_peer_endpoint(&endpoint, generation)?;
                if let Some(previous) = previous_endpoint
                    && endpoint.sequence > previous.sequence
                {
                    self.database
                        .enqueue_endpoint_update_for_contacts(&PeerEndpointUpdate {
                            previous_sequence: previous.sequence,
                            endpoint: endpoint.clone(),
                        })?;
                }
                if let Some(peer) = &self.peer_transport {
                    peer.set_local_endpoint(endpoint.clone());
                }
                self.local_peer_endpoint = Some(endpoint);
                self.refresh_peer_authorizations()?;
                let _ = self.queue_endpoint_update_probes();
                let _ = self.send_capability_offers_for_contacts();
                let mut events = vec![torchat_runtime::RuntimeEvent::PeerEndpointChanged {
                    contact_id: self.identity.installation_id(),
                    status: torchat_runtime::PeerEndpointStatus::Verified,
                }];
                events.push(transport_status_event(
                    torchat_runtime::TransportComponent::Peer,
                    torchat_runtime::TransportProbeState::Ready,
                    "local onion service ready",
                    Some(100),
                    None,
                    0,
                    None,
                    generation,
                    self.local_peer_endpoint
                        .as_ref()
                        .map(|endpoint| endpoint.onion_address.clone()),
                    self.clock.now_ms(),
                ));
                Ok(events)
            }
            PlatformFact::OnionServiceLost { reason } => {
                self.local_peer_endpoint = None;
                self.database.delete_local_peer_endpoint()?;
                self.database.requeue_peer_deliveries(self.clock.now_ms())?;
                Ok(vec![
                    torchat_runtime::RuntimeEvent::PeerEndpointChanged {
                        contact_id: self.identity.installation_id(),
                        status: PeerEndpointStatus::Missing,
                    },
                    torchat_runtime::RuntimeEvent::RuntimeLog {
                        message: format!("onion service unavailable: {reason}"),
                    },
                    transport_status_event(
                        torchat_runtime::TransportComponent::Peer,
                        torchat_runtime::TransportProbeState::Offline,
                        reason,
                        None,
                        None,
                        0,
                        None,
                        self.expected_onion_generation,
                        None,
                        self.clock.now_ms(),
                    ),
                ])
            }
            PlatformFact::AppVisibilityChanged { foreground } => {
                self.app_foreground = foreground;
                let (_, events) = self.with_runtime(|runtime| {
                    runtime.set_app_foreground(foreground);
                    Ok(())
                })?;
                Ok(events)
            }
            PlatformFact::NetworkChanged { online } => {
                self.network_online = online;
                if !online {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.relay.set_socks5_url(None);
                    self.connection_state = ConnectionState::WaitingForTor;
                } else if self.socks5_url.is_some() {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.relay.set_socks5_url(self.socks5_url.clone());
                    self.connection_state = ConnectionState::Connecting;
                    
                    let _ = self.queue_endpoint_update_probes();
                }
                Ok(Vec::new())
            }
            PlatformFact::PowerModeChanged {
                battery_saver,
                device_idle,
            } => {
                self.battery_saver = battery_saver;
                self.device_idle = device_idle;
                Ok(Vec::new())
            }
            PlatformFact::BackgroundExecutionRestricted { restricted } => {
                self.background_restricted = restricted;
                Ok(Vec::new())
            }
        }
    }
}

pub(super) fn runtime_phase_for_tor_ready(_state: &ConnectionState) -> RuntimeStatusPhase {
    RuntimeStatusPhase::Connected
}
