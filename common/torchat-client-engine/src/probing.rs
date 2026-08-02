//! Central scheduling primitives for engine probes.
//!
//! Probes are deliberately transport agnostic.  The coordinator owns timing,
//! deduplication and backoff; the engine supplies the actual probe operation
//! (peer handshake, relay health check, onion listener check, etc.).  This
//! keeps UI/platform code from inventing its own definition of "online".

use std::collections::HashMap;

use tokio::time::{Duration, Instant};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum ProbeKind {
    Engine,
    Relay,
    OnionService,
    ContactPeer,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct ProbeKey {
    pub kind: ProbeKind,
    pub target_id: Option<String>,
}

/// Adapter implemented by a concrete probe (contact, relay, onion service or
/// engine health check).  Implementations only describe their target and
/// cadence; execution remains owned by the engine coordinator.
pub trait Probe {
    fn key(&self) -> ProbeKey;
    fn interval(&self) -> Duration;
}

#[derive(Clone, Debug)]
pub struct ContactProbe {
    pub contact_id: String,
    pub interval: Duration,
}

impl ContactProbe {
    pub fn new(contact_id: impl Into<String>, interval: Duration) -> Self {
        Self {
            contact_id: contact_id.into(),
            interval,
        }
    }
}

impl Probe for ContactProbe {
    fn key(&self) -> ProbeKey {
        ProbeKey::contact(self.contact_id.clone())
    }

    fn interval(&self) -> Duration {
        self.interval
    }
}

impl ProbeKey {
    pub fn contact(contact_id: impl Into<String>) -> Self {
        Self {
            kind: ProbeKind::ContactPeer,
            target_id: Some(contact_id.into()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProbeStatus {
    Unknown,
    Checking,
    Online,
    Offline,
    Degraded,
    Stale,
}

#[derive(Clone, Debug)]
pub struct ProbeState {
    pub status: ProbeStatus,
    pub last_checked_at: Option<Instant>,
    pub next_check_at: Instant,
    pub consecutive_failures: u32,
    pub latency: Option<Duration>,
}

impl ProbeState {
    fn new(now: Instant) -> Self {
        Self {
            status: ProbeStatus::Unknown,
            last_checked_at: None,
            next_check_at: now,
            consecutive_failures: 0,
            latency: None,
        }
    }
}

/// Single owner of probe timing for the engine.
///
/// It does not perform network I/O.  It only decides which probe is due and
/// records the result, so every transport can use the same backoff semantics.
#[derive(Debug)]
pub struct ProbeCoordinator {
    states: HashMap<ProbeKey, ProbeState>,
    next_round_at: Instant,
}

impl ProbeCoordinator {
    pub fn new(now: Instant) -> Self {
        Self {
            states: HashMap::new(),
            next_round_at: now,
        }
    }

    pub fn ensure(&mut self, key: ProbeKey, now: Instant) {
        self.states
            .entry(key)
            .or_insert_with(|| ProbeState::new(now));
    }

    pub fn remove(&mut self, key: &ProbeKey) {
        self.states.remove(key);
    }

    pub fn request_now(&mut self, key: ProbeKey, now: Instant) {
        self.ensure(key.clone(), now);
        if let Some(state) = self.states.get_mut(&key) {
            state.next_check_at = now;
        }
    }

    pub fn next_round_at(&self) -> Instant {
        self.next_round_at
    }

    pub fn schedule_round(&mut self, now: Instant, interval: Duration) {
        self.next_round_at = now + interval;
    }

    /// Returns due probes and marks them as in progress.  A second caller
    /// cannot receive the same probe until `record_result` is called.
    pub fn begin_due(&mut self, now: Instant) -> Vec<ProbeKey> {
        self.states
            .iter_mut()
            .filter_map(|(key, state)| {
                if state.next_check_at > now || state.status == ProbeStatus::Checking {
                    return None;
                }
                state.status = ProbeStatus::Checking;
                Some(key.clone())
            })
            .collect()
    }

    pub fn record_result(
        &mut self,
        key: &ProbeKey,
        now: Instant,
        status: ProbeStatus,
        latency: Option<Duration>,
        base_interval: Duration,
    ) {
        let Some(state) = self.states.get_mut(key) else {
            return;
        };
        state.status = status;
        state.last_checked_at = Some(now);
        state.latency = latency;
        if matches!(status, ProbeStatus::Online | ProbeStatus::Degraded) {
            state.consecutive_failures = 0;
        } else if matches!(status, ProbeStatus::Offline) {
            state.consecutive_failures = state.consecutive_failures.saturating_add(1);
        }
        let exponent = state.consecutive_failures.min(4);
        let multiplier = 1u32 << exponent;
        state.next_check_at = now + base_interval.saturating_mul(multiplier);
    }

    pub fn state(&self, key: &ProbeKey) -> Option<&ProbeState> {
        self.states.get(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn due_probe_is_claimed_once_until_result() {
        let now = Instant::now();
        let key = ProbeKey::contact("peer-a");
        let mut coordinator = ProbeCoordinator::new(now);
        coordinator.ensure(key.clone(), now);

        assert_eq!(coordinator.begin_due(now), vec![key.clone()]);
        assert!(coordinator.begin_due(now).is_empty());

        coordinator.record_result(
            &key,
            now,
            ProbeStatus::Offline,
            None,
            Duration::from_secs(10),
        );
        assert!(coordinator.begin_due(now).is_empty());
    }

    #[test]
    fn failures_back_off_exponentially_and_success_resets_them() {
        let now = Instant::now();
        let key = ProbeKey::contact("peer-a");
        let mut coordinator = ProbeCoordinator::new(now);
        coordinator.ensure(key.clone(), now);

        coordinator.begin_due(now);
        coordinator.record_result(
            &key,
            now,
            ProbeStatus::Offline,
            None,
            Duration::from_secs(10),
        );
        let first = coordinator.state(&key).unwrap().next_check_at;

        coordinator.request_now(key.clone(), first);
        coordinator.begin_due(first);
        coordinator.record_result(
            &key,
            first,
            ProbeStatus::Offline,
            None,
            Duration::from_secs(10),
        );
        let second = coordinator.state(&key).unwrap().next_check_at;
        assert!(second > first);

        coordinator.request_now(key.clone(), second);
        coordinator.begin_due(second);
        coordinator.record_result(
            &key,
            second,
            ProbeStatus::Online,
            Some(Duration::from_millis(4)),
            Duration::from_secs(10),
        );
        assert_eq!(coordinator.state(&key).unwrap().consecutive_failures, 0);
    }
}
