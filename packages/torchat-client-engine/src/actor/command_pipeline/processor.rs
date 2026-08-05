use super::super::*;

use crate::{
    effects::{
        DeferredCommandContext, EngineEffectOutcome, RelayEffectOutcome, RelayEffectResult,
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
                return self.command_refresh_pairing_code(input_id, deferred_context);
            }
            EngineCommand::SubmitPairingCode { code } => {
                return self.command_submit_pairing_code(input_id, deferred_context, code);
            }
            EngineCommand::CancelPairing { pairing_id } => {
                return self.command_cancel_pairing(input_id, deferred_context, pairing_id);
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
        let operation_result = match effect_result {
            RelayEffectResult::PairingCode(Ok(code)) => {
                self.commit_pairing_code_outcome(idempotency.as_ref(), code)
            }
            RelayEffectResult::PairingSubmitted(Ok(item)) => {
                self.commit_pairing_submitted_outcome(idempotency.as_ref(), item)
            }
            RelayEffectResult::PairingCancelled {
                pairing_id,
                result: Ok(()),
            } => self.commit_pairing_cancelled_outcome(idempotency.as_ref(), pairing_id),
            RelayEffectResult::PairingCode(Err(error))
            | RelayEffectResult::PairingSubmitted(Err(error))
            | RelayEffectResult::WorkerFailed(error) => Err(EngineError::Transport(error)),
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

    pub(in crate::actor) fn command_error_result(
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
