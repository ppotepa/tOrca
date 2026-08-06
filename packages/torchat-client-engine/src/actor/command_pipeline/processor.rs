use super::super::*;
use super::stages::{CommandPipelineStage, CommandPipelineTrace};

use crate::{
    effects::{
        DeferredCommandContext, EngineEffectOutcome, RelayEffectOutcome, RelayEffectResult,
    },
    generated::command_contract::command_contract,
    processing::{EngineProcessingResult, ProcessingControl},
};

impl ClientEngineActor {
    pub(in crate::actor) fn process_command_input(
        &mut self,
        input_id: uuid::Uuid,
        envelope: EngineCommandEnvelope,
    ) -> EngineProcessingResult {
        let mut trace = CommandPipelineTrace::default();
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
        trace.complete(CommandPipelineStage::Validate);

        let Some(contract) = command_contract(&command_type) else {
            return self.command_error_result(
                envelope.request_id,
                EngineError::InvalidCommand(format!(
                    "command type is not present in the generated contract: {command_type}"
                )),
            );
        };

        if contract.requires_command_id && command_id.as_deref().is_none_or(str::is_empty) {
            return self.command_error_result(
                envelope.request_id,
                EngineError::InvalidCommand(format!(
                    "durable command {} requires commandId",
                    contract.wire_name
                )),
            );
        }
        trace.complete(CommandPipelineStage::EnforceCommandId);

        let command_descriptor = idempotency_descriptor(&envelope.command, &command_type);
        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;

        let replay = if contract.idempotent {
            match command_id.as_deref() {
                Some(command_id) => match self.database.load_processed_command(command_id) {
                    Ok(value) => value,
                    Err(error) => {
                        return self.command_error_result(envelope.request_id, error);
                    }
                },
                None => None,
            }
        } else {
            None
        };

        if let Some((stored_type, result_json, _revision)) = replay {
            trace.complete(CommandPipelineStage::CheckIdempotency);
            let stored_result = if stored_type != command_descriptor {
                ResponseResult::error(
                    "idempotency_conflict",
                    "command id was already used for a different command",
                )
            } else {
                match serde_json::from_str::<ResponsePayload>(&result_json) {
                    Ok(payload) => ResponseResult::Ok { payload },
                    Err(_) => ResponseResult::error(
                        "idempotency_corrupt",
                        "stored command result is invalid",
                    ),
                }
            };
            trace.complete(CommandPipelineStage::EncodeResponse);
            result.events.push(EngineEvent::Response {
                request_id: envelope.request_id,
                result: stored_result,
            });
            if should_stop {
                result.control = ProcessingControl::Stop;
            }
            return result;
        }
        trace.complete(CommandPipelineStage::CheckIdempotency);

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
                let idempotency = if contract.idempotent {
                    command_id.as_ref().map(|command_id| IdempotencyCommitContext {
                        command_id: command_id.clone(),
                        command_descriptor: command_descriptor.clone(),
                    })
                } else {
                    None
                };
                trace.complete(CommandPipelineStage::OpenTransaction);
                trace.complete(CommandPipelineStage::Execute);
                match self.handle_command(command, idempotency.as_ref()) {
                    Ok((payload, runtime_events, connection_snapshot)) => {
                        trace.complete(CommandPipelineStage::Persist);

                        // Runtime-backed handlers persist their replay result in
                        // the same SQLite transaction as the domain mutation.
                        // Legacy direct-database handlers are retained during
                        // migration, but their fallback is now explicit and any
                        // persistence failure becomes a command failure instead
                        // of being discarded.
                        let idempotency_result = (|| -> EngineResult<()> {
                            if !contract.idempotent {
                                return Ok(());
                            }
                            let Some(command_id) = command_id.as_deref() else {
                                return Ok(());
                            };
                            match self.database.load_processed_command(command_id)? {
                                Some((stored_type, _, _)) if stored_type == command_descriptor => {
                                    Ok(())
                                }
                                Some((stored_type, _, _)) => Err(EngineError::Storage(format!(
                                    "command id {command_id} was persisted for {stored_type} instead of {command_descriptor}"
                                ))),
                                None => {
                                    let (_, revision) = self.projection_head()?;
                                    let result_json = serde_json::to_string(&payload)?;
                                    self.database.save_processed_command(
                                        command_id,
                                        &command_descriptor,
                                        &result_json,
                                        revision,
                                    )
                                }
                            }
                        })();
                        if let Err(error) = idempotency_result {
                            self.pending_engine_events.clear();
                            return self.command_error_result(envelope.request_id, error);
                        }

                        if let Some(snapshot) = connection_snapshot {
                            result.events.push(EngineEvent::Connection { snapshot });
                        }
                        result.extend_runtime_events(runtime_events);
                        result.append_engine_events(&mut self.pending_engine_events);
                        trace.complete(CommandPipelineStage::CollectChanges);
                        trace.complete(CommandPipelineStage::Commit);
                        trace.complete(CommandPipelineStage::ScheduleEffects);
                        trace.complete(CommandPipelineStage::PublishRevision);
                        trace.complete(CommandPipelineStage::EncodeResponse);
                        result.events.push(EngineEvent::Response {
                            request_id: envelope.request_id,
                            result: ResponseResult::Ok { payload },
                        });
                    }
                    Err(error) => {
                        self.pending_engine_events.clear();
                        result.events.push(EngineEvent::Response {
                            request_id: envelope.request_id,
                            result: ResponseResult::error(error_code(&error), error.to_string()),
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

    pub(in crate::actor) fn process_effect_outcome(
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
                pairing_id,
                result: Err(error),
            } => {
                let lifecycle_result = context
                    .command_id
                    .as_deref()
                    .ok_or_else(|| {
                        EngineError::InvalidCommand(
                            "cancel pairing failure is missing its durable operation id".to_owned(),
                        )
                    })
                    .and_then(|operation_id| {
                        self.record_pairing_cancel_failure(operation_id, &pairing_id)
                    });
                match lifecycle_result {
                    Ok(()) => Err(EngineError::Transport(error)),
                    Err(lifecycle_error) => Err(lifecycle_error),
                }
            }
        };

        let mut result = EngineProcessingResult::empty();
        result.scheduler_plan_changed = true;
        match operation_result {
            Ok((payload, runtime_events)) => {
                result.extend_runtime_events(runtime_events);
                result.append_engine_events(&mut self.pending_engine_events);
                result.events.push(EngineEvent::Response {
                    request_id: context.request_id,
                    result: ResponseResult::Ok { payload },
                });
            }
            Err(error) => {
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Response {
                    request_id: context.request_id,
                    result: ResponseResult::error(error_code(&error), error.to_string()),
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
            result: ResponseResult::error(error_code(&error), error.to_string()),
        });
        result
    }
}
