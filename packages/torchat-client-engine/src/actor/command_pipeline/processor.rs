use super::super::*;
use super::stages::{CommandPipelineStage, CommandPipelineTrace};

use crate::{
    effects::{
        DeferredCommandContext, EngineEffectOutcome, RelayEffectOutcome, RelayEffectResult,
    },
    generated::command_contract::command_contract,
    processing::{EngineProcessingResult, ProcessingControl},
};
use torchat_runtime::{RuntimeErrorCategory, RuntimeErrorCode, RuntimeProblem};

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

        if contract.idempotent
            && let Some(command_id) = command_id.as_deref()
            && let Ok(Some((stored_type, result_json, _revision))) =
                self.database.load_processed_command(command_id)
        {
            trace.complete(CommandPipelineStage::CheckIdempotency);
            let stored_result = if stored_type != command_descriptor {
                ResponseResult::error(
                    RuntimeProblem::new(
                        RuntimeErrorCode::Conflict,
                        RuntimeErrorCategory::Domain,
                        false,
                    )
                    .with_diagnostic_context(
                        "command id was already used for a different command",
                    ),
                )
            } else {
                match serde_json::from_str::<ResponsePayload>(&result_json) {
                    Ok(payload) => ResponseResult::Ok { payload },
                    Err(error) => ResponseResult::error(
                        RuntimeProblem::new(
                            RuntimeErrorCode::Internal,
                            RuntimeErrorCategory::Internal,
                            false,
                        )
                        .with_diagnostic_context(format!(
                            "stored command result is invalid: {error}"
                        )),
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
                let idempotency = command_id.as_ref().map(|command_id| {
                    IdempotencyCommitContext {
                        command_id: command_id.clone(),
                        command_descriptor: command_descriptor.clone(),
                    }
                });
                trace.complete(CommandPipelineStage::OpenTransaction);
                trace.complete(CommandPipelineStage::Execute);
                match self.handle_command(command, idempotency.as_ref()) {
                    Ok((payload, runtime_events, connection_snapshot)) => {
                        trace.complete(CommandPipelineStage::Persist);
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
                            result: ResponseResult::from_engine_error(&error),
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
        let mut failure_runtime_events = Vec::new();
        let operation_result = match effect_result {
            RelayEffectResult::PairingCode(Ok(code)) => {
                self.commit_pairing_code_outcome(idempotency.as_ref(), code)
            }
            RelayEffectResult::PairingSubmitted {
                result: Ok(item), ..
            } => self.commit_pairing_submitted_outcome(idempotency.as_ref(), item),
            RelayEffectResult::PairingCancelled {
                pairing_id,
                result: Ok(()),
            } => self.commit_pairing_cancelled_outcome(idempotency.as_ref(), pairing_id),
            RelayEffectResult::PairingCode(Err(error)) => {
                Err(EngineError::Transport(error))
            }
            RelayEffectResult::PairingSubmitted {
                pairing_id,
                result: Err(error),
            } => match self.fail_pairing_operation(
                &pairing_id,
                torchat_runtime::RuntimeErrorCode::TransportUnavailable,
            ) {
                Ok(events) => {
                    failure_runtime_events = events;
                    Err(EngineError::Transport(error))
                }
                Err(state_error) => Err(EngineError::Storage(format!(
                    "record pairing submit failure: {state_error}; relay error: {error}"
                ))),
            },
            RelayEffectResult::PairingCancelled {
                pairing_id,
                result: Err(error),
            } => match self.retry_pairing_operation(&pairing_id) {
                Ok(events) => {
                    failure_runtime_events = events;
                    Err(EngineError::Transport(error))
                }
                Err(state_error) => Err(EngineError::Storage(format!(
                    "record pairing cancel retry: {state_error}; relay error: {error}"
                ))),
            },
            RelayEffectResult::WorkerFailed {
                operation_id,
                error,
            } => {
                if let Some(operation_id) = operation_id {
                    match self.fail_pairing_operation(
                        &operation_id,
                        torchat_runtime::RuntimeErrorCode::Internal,
                    ) {
                        Ok(events) => failure_runtime_events = events,
                        Err(state_error) => {
                            return self.command_error_result(
                                context.request_id,
                                EngineError::Storage(format!(
                                    "record relay worker failure: {state_error}; worker error: {error}"
                                )),
                            );
                        }
                    }
                }
                Err(EngineError::Transport(error))
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
                result.extend_runtime_events(failure_runtime_events);
                self.pending_engine_events.clear();
                result.events.push(EngineEvent::Response {
                    request_id: context.request_id,
                    result: ResponseResult::from_engine_error(&error),
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
            result: ResponseResult::from_engine_error(&error),
        });
        result
    }
}
