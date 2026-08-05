use super::*;

use crate::{
    effects::{
        DeferredCommandContext, EngineEffectEnvelope, EngineEffectOutcome,
        RelayEffectOperation, RelayEffectOutcome, RelayEffectPlaceholder, RelayEffectResult,
    },
    processing::{EngineProcessingResult, ProcessingControl},
};

impl ClientEngineActor {
    pub(super) fn process_command_input(
        &mut self,
        input_id: uuid::Uuid,
        envelope: EngineCommandEnvelope,
    ) -> EngineProcessingResult {
        let should_stop = matches!(&envelope.command, EngineCommand::Shutdown);
        let command_id = envelope.command_id.clone();
        let command_type = serde_json::to_value(&envelope.command)
            .ok()
            .and_then(|value| {
                value
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| "unknown".to_owned());
        let command_descriptor = idempotency_descriptor(&envelope.command, &command_type);
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;

        if let Some(command_id) = command_id.as_deref()
            && let Ok(Some((stored_type, result_json, _revision))) =
                self.database.load_processed_command(command_id)
        {
            let stored_result = if stored_type != command_descriptor {
                ResponseResult::Error {
                    code: "idempotency_conflict".to_owned(),
                    message: "command id was already used for a different command".to_owned(),
                }
            } else {
                match serde_json::from_str::<ResponsePayload>(&result_json) {
                    Ok(payload) => ResponseResult::Ok { payload },
                    Err(_) => ResponseResult::Error {
                        code: "idempotency_corrupt".to_owned(),
                        message: "stored command result is invalid".to_owned(),
                    },
                }
            };
            result.events.push(EngineEvent::Response {
                request_id: envelope.request_id,
                result: stored_result,
            });
            if should_stop {
                result.control = ProcessingControl::Stop;
            }
            return result;
        }

        let deferred_context = DeferredCommandContext {
            request_id: envelope.request_id.clone(),
            command_id: command_id.clone(),
            command_descriptor: command_descriptor.clone(),
        };
        match envelope.command {
            EngineCommand::RefreshPairingCode => {
                return self.defer_relay_effect(
                    input_id,
                    deferred_context,
                    RelayEffectOperation::RefreshPairingCode,
                    Vec::new(),
                );
            }
            EngineCommand::SubmitPairingCode { code } => {
                return match self.prepare_submit_pairing_effect(code) {
                    Ok((operation, runtime_events)) => self.defer_relay_effect(
                        input_id,
                        deferred_context,
                        operation,
                        runtime_events,
                    ),
                    Err(error) => self.command_error_result(envelope.request_id, error),
                };
            }
            EngineCommand::CancelPairing { pairing_id } => {
                return self.defer_relay_effect(
                    input_id,
                    deferred_context,
                    RelayEffectOperation::CancelPairing { pairing_id },
                    Vec::new(),
                );
            }
            command => {
                let idempotency = command_id.as_ref().map(|command_id| {
                    IdempotencyCommitContext {
                        command_id: command_id.clone(),
                        command_descriptor: command_descriptor.clone(),
                    }
                });
                match self.handle_command(command, idempotency.as_ref()) {
                    Ok((payload, runtime_events, connection_snapshot)) => {
                        if let Some(snapshot) = connection_snapshot {
                            result.events.push(EngineEvent::Connection { snapshot });
                        }
                        result.events.extend(
                            runtime_events
                                .into_iter()
                                .map(|event| EngineEvent::Runtime { event }),
                        );
                        result.events.append(&mut self.pending_engine_events);
                        if let Some(command_id) = command_id.as_deref()
                            && let Ok((_, revision)) = self.projection_head()
                            && let Ok(result_json) = serde_json::to_string(&payload)
                        {
                            let _ = self.database.save_processed_command(
                                command_id,
                                &command_descriptor,
                                &result_json,
                                revision,
                            );
                        }
                        result.events.push(EngineEvent::Response {
                            request_id: envelope.request_id,
                            result: ResponseResult::Ok { payload },
                        });
                    }
                    Err(error) => {
                        self.pending_engine_events.clear();
                        result.events.push(EngineEvent::Response {
                            request_id: envelope.request_id,
                            result: ResponseResult::Error {
                                code: error_code(&error).to_owned(),
                                message: error.to_string(),
                            },
                        });
                    }
                }
            }
        }
        if should_stop {
            result.control = ProcessingControl::Stop;
        }
        result
    }

    fn defer_relay_effect(
        &mut self,
        causation_id: uuid::Uuid,
        context: DeferredCommandContext,
        operation: RelayEffectOperation,
        runtime_events: Vec<torchat_runtime::RuntimeEvent>,
    ) -> EngineProcessingResult {
        if !self.relay.can_start_effect() {
            return self.command_error_result(
                context.request_id,
                EngineError::Transport("rendezvous operation is already in progress".to_owned()),
            );
        }
        let relay = std::mem::replace(
            &mut self.relay,
            Box::new(RelayEffectPlaceholder::default()),
        );
        let mut result = EngineProcessingResult::empty();
        result.events.extend(
            runtime_events
                .into_iter()
                .map(|event| EngineEvent::Runtime { event }),
        );
        result.effects.push(EngineEffectEnvelope::relay(
            causation_id,
            context,
            relay,
            operation,
        ));
        result.scheduler_plan_changed = true;
        result
    }

    fn prepare_submit_pairing_effect(
        &mut self,
        code: String,
    ) -> EngineResult<(RelayEffectOperation, Vec<torchat_runtime::RuntimeEvent>)> {
        let (normalized, runtime_events) =
            self.with_runtime(|runtime| runtime.prepare_submit_pairing_code(code))?;
        let pairing_id = uuid::Uuid::new_v4();
        let invite = self.build_contact_invite(None)?;
        let offer = RelayPayloadV1::pairing_offer(
            pairing_id.to_string(),
            String::new(),
            invite,
        )
        .encode()
        .map_err(EngineError::InvalidCommand)?;
        Ok((
            RelayEffectOperation::SubmitPairingCode {
                code: normalized,
                pairing_id,
                offer,
            },
            runtime_events,
        ))
    }

    pub(super) fn process_effect_outcome(
        &mut self,
        outcome: EngineEffectOutcome,
    ) -> EngineProcessingResult {
        match outcome {
            EngineEffectOutcome::Relay(outcome) => self.process_relay_effect_outcome(outcome),
        }
    }

    fn process_relay_effect_outcome(
        &mut self,
        outcome: RelayEffectOutcome,
    ) -> EngineProcessingResult {
        let RelayEffectOutcome {
            effect_id: _,
            context,
            relay,
            result: effect_result,
        } = outcome;
        let deferred_control = self.relay.take_deferred_control();
        self.relay = relay;
        if let Some(socks5_url) = deferred_control.socks5_url {
            self.relay.set_socks5_url(socks5_url);
        }
        if deferred_control.invalidate_session {
            self.relay.invalidate_session();
        }
        let idempotency = context.command_id.as_ref().map(|command_id| {
            IdempotencyCommitContext {
                command_id: command_id.clone(),
                command_descriptor: context.command_descriptor.clone(),
            }
        });
        let operation_result: EngineResult<(
            ResponsePayload,
            Vec<torchat_runtime::RuntimeEvent>,
        )> = match effect_result {
            RelayEffectResult::PairingCode(Ok(code)) => self
                .with_runtime_idempotent(
                    idempotency.as_ref(),
                    |runtime| {
                        runtime.prepare_refresh_pairing_code()?;
                        runtime.commit_pairing_code(code.clone())?;
                        Ok(code.clone())
                    },
                    |value| json_response(value),
                )
                .and_then(|(value, events)| Ok((json_response(value)?, events))),
            RelayEffectResult::PairingSubmitted(Ok(item)) => self
                .with_runtime_idempotent(
                    idempotency.as_ref(),
                    |runtime| runtime.commit_submitted_pairing(item.clone()),
                    |value| json_response(value),
                )
                .and_then(|(value, events)| Ok((json_response(value)?, events))),
            RelayEffectResult::PairingCancelled {
                pairing_id,
                result: Ok(()),
            } => {
                let prepared =
                    self.with_runtime(|runtime| runtime.prepare_cancel_pairing(&pairing_id));
                match prepared {
                    Ok((_, mut events)) => self
                        .with_runtime_idempotent(
                            idempotency.as_ref(),
                            |runtime| runtime.confirm_pairing_cancelled(&pairing_id),
                            |_| Ok(ResponsePayload::Empty),
                        )
                        .map(|(_, confirm_events)| {
                            events.extend(confirm_events);
                            (ResponsePayload::Empty, events)
                        }),
                    Err(error) => Err(error),
                }
            }
            RelayEffectResult::PairingCode(Err(error))
            | RelayEffectResult::PairingSubmitted(Err(error)) => {
                Err(EngineError::Transport(error))
            }
            RelayEffectResult::PairingCancelled {
                result: Err(error),
                ..
            } => Err(EngineError::Transport(error)),
        };

        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match operation_result {
            Ok((payload, runtime_events)) => {
                result.events.extend(
                    runtime_events
                        .into_iter()
                        .map(|event| EngineEvent::Runtime { event }),
                );
                result.events.append(&mut self.pending_engine_events);
                result.events.push(EngineEvent::Response {
                    request_id: context.request_id,
                    result: ResponseResult::Ok { payload },
                });
            }
            Err(error) => {
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Response {
                    request_id: context.request_id,
                    result: ResponseResult::Error {
                        code: error_code(&error).to_owned(),
                        message: error.to_string(),
                    },
                });
            }
        }
        result
    }

    fn command_error_result(
        &mut self,
        request_id: String,
        error: EngineError,
    ) -> EngineProcessingResult {
        self.pending_engine_events.clear();
        let mut result = EngineProcessingResult::empty();
        result.events.push(EngineEvent::Response {
            request_id,
            result: ResponseResult::Error {
                code: error_code(&error).to_owned(),
                message: error.to_string(),
            },
        });
        result
    }
}
