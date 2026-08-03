//! Deterministic workflow harness used by resilience tests.
//! This is intentionally not part of the production transport/runtime.

use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HarnessDelivery {
    Delivered { message_id: String },
    RetryableFailure { message_id: String },
    StorageFailure { message_id: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CrashPoint {
    BeforeCommit,
    AfterCommit,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum HarnessOperationKind {
    Receipt,
    Pairing,
    RelationshipRemoval,
    Capability,
}

#[derive(Clone, Debug)]
struct PendingMessage {
    from: String,
    to: String,
    message_id: String,
    body: String,
}

#[derive(Default)]
pub struct TwoPeerHarness {
    now_ms: i64,
    queue: VecDeque<PendingMessage>,
    received: HashMap<String, Vec<(String, String)>>,
    committed: HashSet<(String, String)>,
    fail_next_transport: bool,
    fail_next_commit: bool,
    crash_next: Option<CrashPoint>,
    committed_operations: HashSet<(HarnessOperationKind, String)>,
}

impl TwoPeerHarness {
    pub fn now_ms(&self) -> i64 {
        self.now_ms
    }

    pub fn advance_ms(&mut self, delta_ms: i64) {
        self.now_ms = self.now_ms.saturating_add(delta_ms);
    }

    pub fn fail_next_transport(&mut self) {
        self.fail_next_transport = true;
    }

    pub fn fail_next_commit(&mut self) {
        self.fail_next_commit = true;
    }

    pub fn crash_next(&mut self, point: CrashPoint) {
        self.crash_next = Some(point);
    }

    pub fn send(&mut self, from: &str, to: &str, message_id: &str, body: &str) {
        self.queue.push_back(PendingMessage {
            from: from.to_owned(),
            to: to.to_owned(),
            message_id: message_id.to_owned(),
            body: body.to_owned(),
        });
    }

    /// Commits a durable non-message operation exactly once. Returning false
    /// means the operation was already committed and is safe to acknowledge.
    pub fn commit_operation(&mut self, kind: HarnessOperationKind, operation_id: &str) -> bool {
        self.committed_operations
            .insert((kind, operation_id.to_owned()))
    }

    pub fn deliver_next(&mut self) -> Option<HarnessDelivery> {
        let message = self.queue.pop_front()?;
        if self.fail_next_transport {
            self.fail_next_transport = false;
            self.queue.push_front(message.clone());
            return Some(HarnessDelivery::RetryableFailure {
                message_id: message.message_id,
            });
        }
        if self.fail_next_commit {
            self.fail_next_commit = false;
            self.queue.push_front(message.clone());
            return Some(HarnessDelivery::StorageFailure {
                message_id: message.message_id,
            });
        }
        if self.crash_next == Some(CrashPoint::BeforeCommit) {
            self.crash_next = None;
            self.queue.push_front(message.clone());
            return Some(HarnessDelivery::StorageFailure {
                message_id: message.message_id,
            });
        }
        let key = (message.to.clone(), message.message_id.clone());
        if self.committed.insert(key) {
            self.received
                .entry(message.to)
                .or_default()
                .push((message.from, message.body));
        }
        if self.crash_next == Some(CrashPoint::AfterCommit) {
            self.crash_next = None;
            return Some(HarnessDelivery::StorageFailure {
                message_id: message.message_id,
            });
        }
        Some(HarnessDelivery::Delivered {
            message_id: message.message_id,
        })
    }

    pub fn received(&self, peer: &str) -> &[(String, String)] {
        self.received.get(peer).map(Vec::as_slice).unwrap_or(&[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_peers_retry_after_transport_fault_without_duplicate_commit() {
        let mut harness = TwoPeerHarness::default();
        harness.send("alice", "bob", "m-1", "hello");
        harness.fail_next_transport();
        assert_eq!(
            harness.deliver_next(),
            Some(HarnessDelivery::RetryableFailure {
                message_id: "m-1".to_owned()
            })
        );
        assert_eq!(harness.now_ms(), 0);
        assert_eq!(
            harness.deliver_next(),
            Some(HarnessDelivery::Delivered {
                message_id: "m-1".to_owned()
            })
        );
        harness.send("alice", "bob", "m-1", "hello");
        assert_eq!(
            harness.deliver_next(),
            Some(HarnessDelivery::Delivered {
                message_id: "m-1".to_owned()
            })
        );
        assert_eq!(harness.received("bob"), [("alice".into(), "hello".into())]);
    }

    #[test]
    fn commit_fault_retries_without_duplicate_persistence() {
        let mut harness = TwoPeerHarness::default();
        harness.send("alice", "bob", "m-2", "persist once");
        harness.fail_next_commit();
        assert_eq!(
            harness.deliver_next(),
            Some(HarnessDelivery::StorageFailure {
                message_id: "m-2".to_owned()
            })
        );
        assert_eq!(
            harness.deliver_next(),
            Some(HarnessDelivery::Delivered {
                message_id: "m-2".to_owned()
            })
        );
        assert_eq!(harness.received("bob").len(), 1);
    }

    #[test]
    fn crash_before_and_after_commit_have_distinct_retry_semantics() {
        let mut harness = TwoPeerHarness::default();
        harness.send("alice", "bob", "before", "one");
        harness.crash_next(CrashPoint::BeforeCommit);
        assert!(matches!(
            harness.deliver_next(),
            Some(HarnessDelivery::StorageFailure { .. })
        ));
        assert!(harness.received("bob").is_empty());
        assert!(matches!(
            harness.deliver_next(),
            Some(HarnessDelivery::Delivered { .. })
        ));

        harness.send("alice", "bob", "after", "two");
        harness.crash_next(CrashPoint::AfterCommit);
        assert!(matches!(
            harness.deliver_next(),
            Some(HarnessDelivery::StorageFailure { .. })
        ));
        assert_eq!(harness.received("bob").len(), 2);
        harness.send("alice", "bob", "after", "two");
        assert!(matches!(
            harness.deliver_next(),
            Some(HarnessDelivery::Delivered { .. })
        ));
        assert_eq!(harness.received("bob").len(), 2);
    }

    #[test]
    fn durable_workflows_share_exactly_once_operation_registry() {
        let mut harness = TwoPeerHarness::default();
        for kind in [
            HarnessOperationKind::Receipt,
            HarnessOperationKind::Pairing,
            HarnessOperationKind::RelationshipRemoval,
            HarnessOperationKind::Capability,
        ] {
            assert!(harness.commit_operation(kind, "op-1"));
            assert!(!harness.commit_operation(kind, "op-1"));
        }
        assert!(harness.commit_operation(HarnessOperationKind::Receipt, "op-2"));
    }

    #[test]
    fn state_machine_invariant_holds_for_deterministic_retry_sequences() {
        let kinds = [
            HarnessOperationKind::Receipt,
            HarnessOperationKind::Pairing,
            HarnessOperationKind::RelationshipRemoval,
            HarnessOperationKind::Capability,
        ];
        let mut harness = TwoPeerHarness::default();
        let mut unique = HashSet::new();
        let mut committed = 0;
        for step in 0..256_u32 {
            let kind = kinds[(step as usize * 17) % kinds.len()];
            let id = format!("op-{}", (step * 13) % 31);
            if unique.insert((kind, id.clone())) && harness.commit_operation(kind, &id) {
                committed += 1;
            }
            // Every third step is a duplicate retry of the same operation.
            if step % 3 == 0 {
                assert!(!harness.commit_operation(kind, &id));
            }
        }
        assert_eq!(committed, unique.len());
        assert!(committed <= 4 * 31);
    }
}
