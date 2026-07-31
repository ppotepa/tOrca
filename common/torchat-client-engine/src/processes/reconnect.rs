#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReconnectState {
    WaitingForNetwork,
    WaitingForTor,
    Connecting { generation: u64 },
    Ready { generation: u64 },
    Backoff {
        generation: u64,
        attempt: u32,
        retry_at_ms: i64,
    },
    Stopped,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReconnectEvent {
    NetworkAvailable,
    NetworkLost,
    TorAvailable,
    TorLost,
    ConnectRequested,
    RelayConnected { generation: u64 },
    RelayDisconnected { generation: u64, reason: String },
    BackoffElapsed { generation: u64 },
    Stop,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReconnectAction {
    WaitForNetwork,
    WaitForTor,
    ConnectRelay { generation: u64 },
    ScheduleRetry {
        generation: u64,
        retry_at_ms: i64,
    },
    MarkReady { generation: u64 },
    Shutdown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReconnectApply {
    Applied(Vec<ReconnectAction>),
    IgnoredStale,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReconnectBackoff {
    pub base_ms: i64,
    pub max_ms: i64,
}

impl Default for ReconnectBackoff {
    fn default() -> Self {
        Self {
            base_ms: 1_000,
            max_ms: 300_000,
        }
    }
}

impl ReconnectBackoff {
    pub fn delay_ms(self, attempt: u32) -> i64 {
        let exponent = attempt.saturating_sub(1).min(20);
        self.base_ms
            .saturating_mul(1_i64 << exponent)
            .min(self.max_ms)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReconnectProcess {
    pub state: ReconnectState,
    pub generation: u64,
    pub attempt: u32,
    pub last_error: Option<String>,
    pub backoff: ReconnectBackoff,
}

impl Default for ReconnectProcess {
    fn default() -> Self {
        Self {
            state: ReconnectState::WaitingForNetwork,
            generation: 0,
            attempt: 0,
            last_error: None,
            backoff: ReconnectBackoff::default(),
        }
    }
}

impl ReconnectProcess {
    pub fn apply(&mut self, event: ReconnectEvent, now_ms: i64) -> ReconnectApply {
        use ReconnectAction as Action;
        use ReconnectApply as Apply;
        use ReconnectEvent as Event;
        use ReconnectState as State;

        match event {
            Event::Stop => {
                self.state = State::Stopped;
                Apply::Applied(vec![Action::Shutdown])
            }
            Event::NetworkLost => {
                self.generation = self.generation.saturating_add(1);
                self.state = State::WaitingForNetwork;
                self.last_error = Some("network unavailable".to_owned());
                Apply::Applied(vec![Action::WaitForNetwork])
            }
            Event::TorLost => {
                self.generation = self.generation.saturating_add(1);
                self.state = State::WaitingForTor;
                self.last_error = Some("Tor endpoint unavailable".to_owned());
                Apply::Applied(vec![Action::WaitForTor])
            }
            Event::NetworkAvailable => {
                if self.state == State::WaitingForNetwork {
                    self.state = State::WaitingForTor;
                    Apply::Applied(vec![Action::WaitForTor])
                } else {
                    Apply::Applied(Vec::new())
                }
            }
            Event::TorAvailable | Event::ConnectRequested => {
                self.generation = self.generation.saturating_add(1);
                self.state = State::Connecting {
                    generation: self.generation,
                };
                Apply::Applied(vec![Action::ConnectRelay {
                    generation: self.generation,
                }])
            }
            Event::RelayConnected { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                self.attempt = 0;
                self.last_error = None;
                self.state = State::Ready { generation };
                Apply::Applied(vec![Action::MarkReady { generation }])
            }
            Event::RelayDisconnected { generation, reason } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                self.attempt = self.attempt.saturating_add(1);
                self.last_error = Some(reason);
                let retry_at_ms = now_ms.saturating_add(self.backoff.delay_ms(self.attempt));
                self.state = State::Backoff {
                    generation,
                    attempt: self.attempt,
                    retry_at_ms,
                };
                Apply::Applied(vec![Action::ScheduleRetry {
                    generation,
                    retry_at_ms,
                }])
            }
            Event::BackoffElapsed { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                self.generation = self.generation.saturating_add(1);
                self.state = State::Connecting {
                    generation: self.generation,
                };
                Apply::Applied(vec![Action::ConnectRelay {
                    generation: self.generation,
                }])
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_uses_one_generation_owner_and_backoff() {
        let mut process = ReconnectProcess::default();
        process.apply(ReconnectEvent::NetworkAvailable, 0);
        let action = process.apply(ReconnectEvent::TorAvailable, 0);
        assert_eq!(
            action,
            ReconnectApply::Applied(vec![ReconnectAction::ConnectRelay { generation: 1 }])
        );
        let action = process.apply(
            ReconnectEvent::RelayDisconnected {
                generation: 1,
                reason: "relay closed".to_owned(),
            },
            10,
        );
        assert_eq!(
            action,
            ReconnectApply::Applied(vec![ReconnectAction::ScheduleRetry {
                generation: 1,
                retry_at_ms: 1_010,
            }])
        );
    }

    #[test]
    fn stale_relay_events_are_ignored() {
        let mut process = ReconnectProcess::default();
        process.apply(ReconnectEvent::TorAvailable, 0);
        process.apply(ReconnectEvent::NetworkLost, 1);

        assert_eq!(
            process.apply(ReconnectEvent::RelayConnected { generation: 1 }, 2),
            ReconnectApply::IgnoredStale
        );
    }
}
