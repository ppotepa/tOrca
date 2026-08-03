//! Central scheduling primitives for engine probes.
//!
//! Probes are deliberately transport agnostic.  The coordinator owns timing,
//! deduplication and backoff; the engine supplies the actual probe operation
//! (peer handshake, relay health check, onion listener check, etc.).  This
//! keeps UI/platform code from inventing its own definition of "online".

use std::collections::HashMap;

use sha2::{Digest, Sha256};
use tokio::sync::watch;
use tokio::time::{Duration, Instant};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum ProbeKind {
    Engine,
    Relay,
    OnionService,
    ContactPeer,
    ContactPresence,
    ContactFocus,
    PeerEndpoint,
    Capability,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct ProbeKey {
    pub kind: ProbeKind,
    pub target_id: Option<String>,
}

pub fn pseudonymous_target_id(target_id: &str) -> String {
    let digest = Sha256::digest(target_id.as_bytes());
    digest[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
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
    pub fn new(kind: ProbeKind, target_id: Option<String>) -> Self {
        Self { kind, target_id }
    }

    pub fn contact(contact_id: impl Into<String>) -> Self {
        Self::new(ProbeKind::ContactPeer, Some(contact_id.into()))
    }

    pub fn contact_presence(contact_id: impl Into<String>) -> Self {
        Self::new(ProbeKind::ContactPresence, Some(contact_id.into()))
    }

    pub fn contact_focus(contact_id: impl Into<String>) -> Self {
        Self::new(ProbeKind::ContactFocus, Some(contact_id.into()))
    }

    pub fn peer_endpoint(contact_id: impl Into<String>) -> Self {
        Self::new(ProbeKind::PeerEndpoint, Some(contact_id.into()))
    }

    pub fn capability(contact_id: impl Into<String>) -> Self {
        Self::new(ProbeKind::Capability, Some(contact_id.into()))
    }

    pub fn engine() -> Self {
        Self::new(ProbeKind::Engine, None)
    }

    pub fn relay() -> Self {
        Self::new(ProbeKind::Relay, None)
    }

    pub fn onion_service() -> Self {
        Self::new(ProbeKind::OnionService, None)
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
    pub revision: u64,
    pub in_flight_until: Option<Instant>,
}

impl ProbeState {
    fn new(now: Instant) -> Self {
        Self {
            status: ProbeStatus::Unknown,
            last_checked_at: None,
            next_check_at: now,
            consecutive_failures: 0,
            latency: None,
            revision: 0,
            in_flight_until: None,
        }
    }

    fn snapshot(&self, key: &ProbeKey) -> ProbeSnapshot {
        ProbeSnapshot {
            key: key.clone(),
            status: self.status,
            last_checked_at: self.last_checked_at,
            next_check_at: self.next_check_at,
            consecutive_failures: self.consecutive_failures,
            latency: self.latency,
            revision: self.revision,
            in_flight_until: self.in_flight_until,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProbeSnapshot {
    pub key: ProbeKey,
    pub status: ProbeStatus,
    pub last_checked_at: Option<Instant>,
    pub next_check_at: Instant,
    pub consecutive_failures: u32,
    pub latency: Option<Duration>,
    pub revision: u64,
    pub in_flight_until: Option<Instant>,
}

/// All contact-scoped probe streams exposed as one subscription boundary.
/// Consumers can render a contact summary or inspect a technical detail
/// without registering independent schedulers for each probe kind.
pub struct ContactProbeSubscription {
    pub peer: watch::Receiver<ProbeSnapshot>,
    pub presence: watch::Receiver<ProbeSnapshot>,
    pub focus: watch::Receiver<ProbeSnapshot>,
    pub endpoint: watch::Receiver<ProbeSnapshot>,
    pub capability: watch::Receiver<ProbeSnapshot>,
}

#[derive(Debug)]
struct ProbeEntry {
    state: ProbeState,
    snapshot_tx: watch::Sender<ProbeSnapshot>,
}

impl ProbeEntry {
    fn new(key: &ProbeKey, now: Instant) -> Self {
        let state = ProbeState::new(now);
        let (snapshot_tx, _) = watch::channel(state.snapshot(key));
        Self { state, snapshot_tx }
    }

    fn publish(&self, key: &ProbeKey) {
        self.snapshot_tx.send_replace(self.state.snapshot(key));
    }
}

/// Single owner of probe timing for the engine.
///
/// It does not perform network I/O.  It only decides which probe is due and
/// records the result, so every transport can use the same backoff semantics.
#[derive(Debug)]
pub struct ProbeCoordinator {
    entries: HashMap<ProbeKey, ProbeEntry>,
    next_round_at: Instant,
}

impl ProbeCoordinator {
    pub fn new(now: Instant) -> Self {
        Self {
            entries: HashMap::new(),
            next_round_at: now,
        }
    }

    pub fn ensure(&mut self, key: ProbeKey, now: Instant) {
        self.entries
            .entry(key.clone())
            .or_insert_with(|| ProbeEntry::new(&key, now));
    }

    pub fn remove(&mut self, key: &ProbeKey) {
        self.entries.remove(key);
    }

    pub fn request_now(&mut self, key: ProbeKey, now: Instant) {
        self.ensure(key.clone(), now);
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.state.next_check_at = now;
            entry.state.revision = entry.state.revision.saturating_add(1);
            entry.publish(&key);
        }
    }

    /// Returns a retained stream for one probe. New subscribers immediately
    /// receive the latest snapshot and never trigger duplicate network work.
    pub fn subscribe(&mut self, key: ProbeKey, now: Instant) -> watch::Receiver<ProbeSnapshot> {
        self.ensure(key.clone(), now);
        self.entries
            .get(&key)
            .expect("probe entry exists after ensure")
            .snapshot_tx
            .subscribe()
    }

    pub fn subscribe_contact(
        &mut self,
        contact_id: impl Into<String>,
        now: Instant,
    ) -> ContactProbeSubscription {
        let contact_id = contact_id.into();
        ContactProbeSubscription {
            peer: self.subscribe(ProbeKey::contact(contact_id.clone()), now),
            presence: self.subscribe(ProbeKey::contact_presence(contact_id.clone()), now),
            focus: self.subscribe(ProbeKey::contact_focus(contact_id.clone()), now),
            endpoint: self.subscribe(ProbeKey::peer_endpoint(contact_id.clone()), now),
            capability: self.subscribe(ProbeKey::capability(contact_id), now),
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
        self.begin_due_with_timeout(now, Duration::from_secs(30))
    }

    pub fn begin_due_with_timeout(&mut self, now: Instant, timeout: Duration) -> Vec<ProbeKey> {
        self.entries
            .iter_mut()
            .filter_map(|(key, entry)| {
                let actively_checking = entry.state.status == ProbeStatus::Checking
                    && entry
                        .state
                        .in_flight_until
                        .is_some_and(|deadline| deadline > now);
                if entry.state.next_check_at > now || actively_checking {
                    return None;
                }
                entry.state.status = ProbeStatus::Checking;
                entry.state.in_flight_until = Some(now + timeout);
                entry.state.revision = entry.state.revision.saturating_add(1);
                entry.publish(key);
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
        let Some(entry) = self.entries.get_mut(key) else {
            return;
        };
        let state = &mut entry.state;
        state.status = status;
        state.last_checked_at = Some(now);
        state.latency = latency;
        state.in_flight_until = None;
        if matches!(status, ProbeStatus::Online | ProbeStatus::Degraded) {
            state.consecutive_failures = 0;
        } else if matches!(status, ProbeStatus::Offline) {
            state.consecutive_failures = state.consecutive_failures.saturating_add(1);
        }
        let exponent = state.consecutive_failures.min(4);
        let multiplier = 1u32 << exponent;
        state.next_check_at = now + base_interval.saturating_mul(multiplier);
        state.revision = state.revision.saturating_add(1);
        entry.publish(key);
    }

    pub fn state(&self, key: &ProbeKey) -> Option<&ProbeState> {
        self.entries.get(key).map(|entry| &entry.state)
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

    #[test]
    fn subscribers_share_one_retained_probe_snapshot() {
        let now = Instant::now();
        let key = ProbeKey::contact("peer-a");
        let mut coordinator = ProbeCoordinator::new(now);
        let mut list = coordinator.subscribe(key.clone(), now);
        let mut header = coordinator.subscribe(key.clone(), now);

        assert_eq!(list.borrow().status, ProbeStatus::Unknown);
        assert_eq!(header.borrow().revision, 0);
        assert_eq!(coordinator.begin_due(now), vec![key.clone()]);
        assert!(list.has_changed().unwrap());
        assert!(header.has_changed().unwrap());
        assert_eq!(list.borrow_and_update().status, ProbeStatus::Checking);
        assert_eq!(header.borrow_and_update().status, ProbeStatus::Checking);

        coordinator.record_result(
            &key,
            now,
            ProbeStatus::Online,
            Some(Duration::from_millis(7)),
            Duration::from_secs(30),
        );
        assert!(list.has_changed().unwrap());
        assert!(header.has_changed().unwrap());
        assert_eq!(list.borrow().latency, Some(Duration::from_millis(7)));
        assert_eq!(header.borrow().status, ProbeStatus::Online);
    }

    #[test]
    fn removing_probe_closes_its_subscriptions() {
        let now = Instant::now();
        let key = ProbeKey::contact("peer-a");
        let mut coordinator = ProbeCoordinator::new(now);
        let receiver = coordinator.subscribe(key.clone(), now);

        coordinator.remove(&key);

        assert!(receiver.has_changed().is_err());
    }

    #[test]
    fn abandoned_in_flight_probe_can_be_claimed_after_timeout() {
        let now = Instant::now();
        let key = ProbeKey::contact("peer-a");
        let mut coordinator = ProbeCoordinator::new(now);
        coordinator.ensure(key.clone(), now);

        assert_eq!(
            coordinator.begin_due_with_timeout(now, Duration::from_secs(5)),
            vec![key.clone()]
        );
        assert!(
            coordinator
                .begin_due_with_timeout(now + Duration::from_secs(4), Duration::from_secs(5))
                .is_empty()
        );
        assert_eq!(
            coordinator
                .begin_due_with_timeout(now + Duration::from_secs(5), Duration::from_secs(5)),
            vec![key]
        );
    }
}
