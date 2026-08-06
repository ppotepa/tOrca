use super::*;

impl ClientEngineActor {
    pub(crate) fn queue_read_receipts(
        &mut self,
        conversation_id: &str,
        mut message_ids: Vec<uuid::Uuid>,
    ) -> EngineResult<()> {
        message_ids.sort_unstable();
        message_ids.dedup();
        if message_ids.is_empty() {
            return Ok(());
        }
        let message_ids_json = serde_json::to_string(&message_ids)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        self.database.enqueue_read_receipt(
            conversation_id,
            conversation_id,
            &message_ids_json,
            self.clock.now_ms(),
            self.clock.now_ms(),
        )?;
        self.flush_pending_read_receipts()
    }

    pub(crate) fn flush_pending_read_receipts(&mut self) -> EngineResult<()> {
        for record in self.database.due_read_receipts(self.clock.now_ms())? {
            let payload = if let Some(payload) = record.wire_ciphertext.clone() {
                payload
            } else {
                let ids: Vec<uuid::Uuid> = serde_json::from_str(&record.message_ids_json)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
                let mut conversation = self
                    .conversations
                    .remove(&record.conversation_id)
                    .ok_or_else(|| {
                        EngineError::InvalidCommand(
                            "contact requires MLS welcome before sending read receipt".to_owned(),
                        )
                    })?;
                let before = conversation
                    .snapshot()
                    .map_err(|error| EngineError::Storage(error.to_string()))?;
                let encrypted: EngineResult<String> = (|| {
                    let plaintext = ApplicationPayloadV1::ReadReceipt {
                        version: torchat_core::PROTOCOL_VERSION,
                        message_ids: ids,
                        read_at: record.read_at,
                    }
                    .encode()
                    .map_err(EngineError::InvalidCommand)?;
                    let ciphertext = conversation
                        .encrypt(&plaintext)
                        .map_err(EngineError::InvalidCommand)?;
                    let payload = PeerCiphertextPayload::new(&ciphertext)
                        .encode()
                        .map_err(EngineError::InvalidCommand)?;
                    let after = conversation
                        .snapshot()
                        .map_err(|error| EngineError::Storage(error.to_string()))?;
                    self.database.persist_read_receipt_encryption(
                        &record.receipt_id,
                        payload.as_bytes(),
                        &record.conversation_id,
                        &after,
                        self.clock.now_ms() + retry_backoff_ms(record.attempt_count),
                    )?;
                    Ok(payload)
                })();
                match encrypted {
                    Ok(payload) => {
                        self.conversations
                            .insert(record.conversation_id.clone(), conversation);
                        payload.into_bytes()
                    }
                    Err(error) => {
                        let restored = DirectConversation::restore(&before)
                            .map_err(|restore| EngineError::Storage(restore.to_string()))?;
                        self.conversations
                            .insert(record.conversation_id.clone(), restored);
                        self.database.requeue_read_receipt(
                            &record.receipt_id,
                            self.clock.now_ms() + retry_backoff_ms(record.attempt_count),
                            &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                        )?;
                        continue;
                    }
                }
            };
            let envelope_id = uuid::Uuid::parse_str(&record.receipt_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            if let Err(error) = self.queue_peer_payload(
                envelope_id,
                &record.contact_installation_id,
                &record.conversation_id,
                stable_message_sequence(envelope_id),
                payload.clone(),
                PeerDeliveryTag::ReadReceipt {
                    receipt_id: record.receipt_id.clone(),
                },
            ) {
                self.database.requeue_read_receipt(
                    &record.receipt_id,
                    self.clock.now_ms() + retry_backoff_ms(record.attempt_count),
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
            }
        }
        Ok(())
    }
}

impl ClientEngineActor {
    pub(crate) fn dispatch_outbound_receipt(
        &mut self,
        receipt: &torchat_runtime::ReceiptSendEffect,
        envelope_id: uuid::Uuid,
        sequence: u64,
        ciphertext: String,
    ) -> EngineResult<()> {
        let peer_result = self.queue_peer_payload(
            envelope_id,
            &receipt.recipient_installation_id,
            &receipt.conversation_id,
            sequence,
            ciphertext.clone().into_bytes(),
            PeerDeliveryTag::Receipt {
                message_id: receipt.message_id.clone(),
            },
        );
        if let Err(error) = peer_result {
            self.handle_failed_peer_receipt_delivery(
                &receipt.recipient_installation_id,
                &receipt.message_id,
                &error.to_string(),
            )?;
        }
        Ok(())
    }

    pub(crate) fn handle_failed_peer_receipt_delivery(
        &mut self,
        installation_id: &str,
        message_id: &str,
        error: &str,
    ) -> EngineResult<()> {
        let receipt = self.database.delivery_receipt(message_id)?;
        let attempt = receipt
            .as_ref()
            .map(|record| record.attempt_count)
            .unwrap_or(0);
        let age_exhausted = receipt.as_ref().is_some_and(|record| {
            super::RetryPolicy::DELIVERY
                .age_exhausted(record.created_at.saturating_mul(1_000), self.clock.now_ms())
        });
        let exhausted = super::RetryPolicy::DELIVERY.exhausted(attempt) || age_exhausted;
        let retry_at = if exhausted {
            // Keep the durable receipt record for diagnostics/reconciliation,
            // but stop scheduling an unbounded retry loop.
            i64::MAX
        } else {
            self.clock.now_ms() + retry_backoff_ms(attempt)
        };
        if exhausted {
            self.database
                .mark_delivery_receipt_dead_lettered("retry_exhausted", message_id)?;
            self.database.record_delivery_dead_letter(
                "receipt",
                message_id,
                Some(installation_id),
                attempt,
                error,
            )?;
        }
        self.database
            .requeue_delivery_receipt(message_id, retry_at, error)?;
        Ok(())
    }

    pub(crate) fn flush_pending_receipt_effects(&mut self) -> EngineResult<()> {
        let (effects, _) =
            self.with_runtime(|runtime| runtime.prepare_pending_receipt_effects())?;
        for effect in effects {
            self.deliver_send_effect(RuntimeSendEffect::from(effect))?;
        }
        Ok(())
    }

    pub(crate) fn encrypt_receipt(
        &mut self,
        effect: &torchat_runtime::ReceiptSendEffect,
    ) -> EngineResult<String> {
        let stored = self
            .database
            .delivery_receipt(&effect.message_id)?
            .ok_or_else(|| EngineError::Storage("delivery receipt is missing".to_owned()))?;
        let in_flight_until = self.clock.now_ms() + 60_000;
        if let Some(existing) = stored.wire_ciphertext {
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
