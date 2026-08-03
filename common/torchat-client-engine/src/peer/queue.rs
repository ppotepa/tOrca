use std::collections::{HashSet, VecDeque};

use tokio::time::Instant;

use super::types::{PeerDeliveryTag, PeerOutboundCommand};

#[derive(Default)]
pub(super) struct CommandQueues {
    durable: VecDeque<PeerOutboundCommand>,
    endpoint_update: Option<PeerOutboundCommand>,
    probe: Option<PeerOutboundCommand>,
    ephemeral: Option<PeerOutboundCommand>,
    dedupe: HashSet<String>,
}

impl CommandQueues {
    pub(super) fn enqueue(&mut self, command: PeerOutboundCommand) {
        if matches!(
            &command.delivery,
            PeerDeliveryTag::Message { .. }
                | PeerDeliveryTag::Receipt { .. }
                | PeerDeliveryTag::ReadReceipt { .. }
        ) {
            if self.insert_dedupe(&command) {
                // Message and receipt ciphertexts advance the same MLS state.
                // Their encryption/enqueue order must therefore also be their
                // wire order; prioritizing messages over earlier receipts can
                // skip a generation at the receiver.
                self.durable.push_back(command);
            }
        } else if matches!(&command.delivery, PeerDeliveryTag::EndpointUpdate) {
            self.endpoint_update = Some(command);
        } else if matches!(&command.delivery, PeerDeliveryTag::Probe) {
            self.probe = Some(command);
        } else {
            self.ephemeral = Some(command);
        }
    }

    fn insert_dedupe(&mut self, command: &PeerOutboundCommand) -> bool {
        command
            .delivery
            .dedupe_key()
            .is_none_or(|key| self.dedupe.insert(key))
    }

    pub(super) fn complete(&mut self, delivery: &PeerDeliveryTag) {
        if let Some(key) = delivery.dedupe_key() {
            self.dedupe.remove(&key);
        }
    }

    pub(super) fn has_dial_worthy(&self) -> bool {
        !self.durable.is_empty() || self.endpoint_update.is_some() || self.probe.is_some()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.durable.is_empty()
            && self.endpoint_update.is_none()
            && self.probe.is_none()
            && self.ephemeral.is_none()
    }

    pub(super) fn connection_template(&self) -> Option<&PeerOutboundCommand> {
        self.durable
            .front()
            .or(self.endpoint_update.as_ref())
            .or(self.probe.as_ref())
    }

    pub(super) fn pop_next(&mut self, session_ready: bool) -> Option<PeerOutboundCommand> {
        if let Some(durable) = self.durable.pop_front() {
            return Some(durable);
        }
        self.endpoint_update
            .take()
            .or_else(|| self.probe.take())
            .or_else(|| session_ready.then(|| self.ephemeral.take()).flatten())
    }

    pub(super) fn push_front(&mut self, command: PeerOutboundCommand) {
        if matches!(
            &command.delivery,
            PeerDeliveryTag::Message { .. }
                | PeerDeliveryTag::Receipt { .. }
                | PeerDeliveryTag::ReadReceipt { .. }
        ) {
            self.durable.push_front(command);
        } else if matches!(&command.delivery, PeerDeliveryTag::EndpointUpdate) {
            self.endpoint_update = Some(command);
        } else if matches!(&command.delivery, PeerDeliveryTag::Probe) {
            self.probe = Some(command);
        } else {
            self.ephemeral = Some(command);
        }
    }

    pub(super) fn drop_ephemeral_without_session(&mut self) {
        self.ephemeral = None;
    }

    pub(super) fn drain_failed(&mut self) -> Vec<PeerOutboundCommand> {
        let mut commands = Vec::new();
        commands.extend(self.durable.drain(..));
        if let Some(command) = self.endpoint_update.take() {
            commands.push(command);
        }
        self.probe = None;
        self.ephemeral = None;
        for command in &commands {
            self.complete(&command.delivery);
        }
        commands
    }
}

pub(super) struct ActiveDelivery {
    pub(super) delivery: PeerDeliveryTag,
    pub(super) expected_ciphertext_hash: [u8; 32],
    pub(super) endpoint_sequence: Option<u64>,
    pub(super) sent_at: Instant,
}

pub(super) struct EndpointProbe {
    pub(super) endpoint_sequence: Option<u64>,
    pub(super) sent_at: Instant,
    pub(super) delivery: PeerDeliveryTag,
}

#[cfg(test)]
mod tests {
    use super::*;
    use torchat_core::{PROTOCOL_VERSION, peer_protocol::PeerEndpointBundle};
    use uuid::Uuid;

    fn endpoint() -> PeerEndpointBundle {
        PeerEndpointBundle {
            protocol_version: PROTOCOL_VERSION,
            installation_id: "peer".to_owned(),
            onion_address: format!("{}.onion", "a".repeat(56)),
            virtual_port: 443,
            identity_public_key: "key".to_owned(),
            capabilities: vec!["peer_message_v1".to_owned()],
            sequence: 1,
            issued_at: 1,
            expires_at: None,
            signature: "signature".to_owned(),
        }
    }

    fn command(delivery: PeerDeliveryTag, message_id: Uuid) -> PeerOutboundCommand {
        PeerOutboundCommand {
            endpoint: endpoint(),
            capability_id: String::new(),
            capability_secret: Vec::new(),
            peer_public_key: "key".to_owned(),
            local_endpoint: endpoint(),
            endpoint_updates: Vec::new(),
            message_id,
            conversation_id: "conversation".to_owned(),
            sequence: 1,
            created_at: 1,
            ciphertext: vec![1],
            delivery,
            socks5_url: "socks5h://127.0.0.1:9050".to_owned(),
        }
    }

    #[test]
    fn durable_messages_are_prioritized_over_ephemeral_state() {
        let mut queues = CommandQueues::default();
        let ephemeral_id = Uuid::new_v4();
        let message_id = Uuid::new_v4();
        queues.enqueue(command(PeerDeliveryTag::Ephemeral, ephemeral_id));
        queues.enqueue(command(
            PeerDeliveryTag::Message {
                message_id: message_id.to_string(),
            },
            message_id,
        ));

        assert!(matches!(
            queues.pop_next(true).unwrap().delivery,
            PeerDeliveryTag::Message { .. }
        ));
        assert!(matches!(
            queues.pop_next(true).unwrap().delivery,
            PeerDeliveryTag::Ephemeral
        ));
    }

    #[test]
    fn ephemeral_state_is_latest_only() {
        let mut queues = CommandQueues::default();
        let first = Uuid::new_v4();
        let latest = Uuid::new_v4();
        queues.enqueue(command(PeerDeliveryTag::Ephemeral, first));
        queues.enqueue(command(PeerDeliveryTag::Ephemeral, latest));

        let queued = queues.pop_next(true).unwrap();
        assert_eq!(queued.message_id, latest);
        assert!(queues.pop_next(true).is_none());
    }

    #[test]
    fn duplicate_durable_delivery_is_coalesced() {
        let mut queues = CommandQueues::default();
        let message_id = Uuid::new_v4();
        let delivery = PeerDeliveryTag::Message {
            message_id: message_id.to_string(),
        };
        queues.enqueue(command(delivery.clone(), message_id));
        queues.enqueue(command(delivery, message_id));

        assert!(queues.pop_next(true).is_some());
        assert!(queues.pop_next(true).is_none());
    }

    #[test]
    fn durable_ciphertexts_preserve_mls_generation_order() {
        let mut queues = CommandQueues::default();
        let receipt_id = Uuid::new_v4();
        let message_id = Uuid::new_v4();
        queues.enqueue(command(
            PeerDeliveryTag::Receipt {
                message_id: receipt_id.to_string(),
            },
            receipt_id,
        ));
        queues.enqueue(command(
            PeerDeliveryTag::Message {
                message_id: message_id.to_string(),
            },
            message_id,
        ));

        assert!(matches!(
            queues.pop_next(true).unwrap().delivery,
            PeerDeliveryTag::Receipt { .. }
        ));
        assert!(matches!(
            queues.pop_next(true).unwrap().delivery,
            PeerDeliveryTag::Message { .. }
        ));
    }
}
