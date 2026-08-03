use super::*;

impl ClientEngineActor {
    pub(super) fn dispatch_outbound_receipt(
        &mut self,
        receipt: &torchat_client_runtime::ReceiptSendEffect,
        envelope_id: uuid::Uuid,
        sequence: u64,
        ciphertext: String,
    ) -> EngineResult<()> {
        let policy = self.contact_transport_policy(&receipt.recipient_installation_id)?;
        let peer_result = if matches!(policy, ContactTransportPolicy::RelayOnly) {
            Err(EngineError::Transport(
                "peer route disabled by contact policy".to_owned(),
            ))
        } else {
            self.queue_peer_payload(
                envelope_id,
                &receipt.recipient_installation_id,
                &receipt.conversation_id,
                sequence,
                ciphertext.clone().into_bytes(),
                PeerDeliveryTag::Receipt {
                    message_id: receipt.message_id.clone(),
                },
            )
        };
        if let Err(error) = peer_result {
            self.handle_failed_peer_receipt_delivery(
                &receipt.recipient_installation_id,
                &receipt.message_id,
                &error.to_string(),
            )?;
        }
        Ok(())
    }

    pub(super) fn handle_failed_peer_receipt_delivery(
        &mut self,
        installation_id: &str,
        message_id: &str,
        error: &str,
    ) -> EngineResult<()> {
        let policy = self.contact_transport_policy(installation_id)?;
        let payload = self
            .database
            .delivery_receipt(message_id)?
            .and_then(|receipt| receipt.relay_payload)
            .ok_or_else(|| {
                EngineError::Storage("delivery receipt payload is missing".to_owned())
            })?;
        let payload = String::from_utf8(payload).map_err(|decode_error| {
            EngineError::Storage(format!(
                "stored delivery receipt payload is invalid UTF-8: {decode_error}"
            ))
        })?;
        let envelope_id = uuid::Uuid::parse_str(message_id)
            .map_err(|parse_error| EngineError::InvalidCommand(parse_error.to_string()))?;
        if matches!(
            policy,
            ContactTransportPolicy::PeerWithRelayFallback | ContactTransportPolicy::RelayOnly
        ) && self
            .queue_relay_envelope(
                envelope_id,
                installation_id,
                &payload,
                PendingRelayDelivery::Receipt {
                    message_id: message_id.to_owned(),
                },
            )
            .is_ok()
        {
            return Ok(());
        }
        let attempt = self
            .database
            .delivery_receipt(message_id)?
            .map(|record| record.attempt_count)
            .unwrap_or(0);
        self.database.requeue_delivery_receipt(
            message_id,
            unix_ms() + retry_backoff_ms(attempt),
            error,
        )?;
        Ok(())
    }

    pub(super) fn apply_message_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let parsed = uuid::Uuid::parse_str(message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let (_, runtime_events) =
            self.with_runtime(|runtime| runtime.apply_message_transport_outcome(parsed, outcome))?;
        Ok(runtime_events)
    }

    pub(super) fn flush_pending_receipt_effects(&mut self) -> EngineResult<()> {
        let (effects, _) =
            self.with_runtime(|runtime| runtime.prepare_pending_receipt_effects())?;
        for effect in effects {
            self.deliver_send_effect(RuntimeSendEffect::from(effect))?;
        }
        Ok(())
    }

    pub(super) fn encrypt_receipt(
        &mut self,
        effect: &torchat_client_runtime::ReceiptSendEffect,
    ) -> EngineResult<String> {
        let stored = self
            .database
            .delivery_receipt(&effect.message_id)?
            .ok_or_else(|| EngineError::Storage("delivery receipt is missing".to_owned()))?;
        let in_flight_until = unix_ms() + 60_000;
        if let Some(existing) = stored.relay_payload {
            if !self
                .database
                .claim_receipt_attempt(&effect.message_id, in_flight_until, None)?
            {
                return Err(EngineError::Storage(
                    "delivery receipt could not be claimed for retry".to_owned(),
                ));
            }
            return String::from_utf8(existing).map_err(|error| {
                EngineError::Storage(format!(
                    "stored delivery receipt payload is invalid UTF-8: {error}"
                ))
            });
        }

        let mut conversation = self
            .conversations
            .remove(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand("receipt recipient has no MLS conversation".to_owned())
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let encryption_result = (|| {
            let plaintext = ApplicationPayloadV1::DeliveryReceipt {
                version: torchat_core::PROTOCOL_VERSION,
                message_id: uuid::Uuid::parse_str(&effect.message_id)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                received_at: effect.received_at,
            }
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(EngineError::InvalidCommand)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            if !self.database.persist_receipt_encryption(
                &effect.message_id,
                payload.as_bytes(),
                &effect.conversation_id,
                &snapshot_after,
                in_flight_until,
                None,
            )? {
                return Err(EngineError::Storage(
                    "delivery receipt could not be claimed for encryption".to_owned(),
                ));
            }
            Ok(payload)
        })();

        match encryption_result {
            Ok(payload) => {
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), conversation);
                Ok(payload)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after receipt rollback: {restore_error}"
                        ))
                    })?;
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), restored);
                Err(error)
            }
        }
    }
}
