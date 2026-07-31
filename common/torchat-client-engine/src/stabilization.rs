use crate::{
    BackpressureDecision, BackpressurePolicy, CommandFamily, CommandRoute, CommandRouter,
    EngineCommandEnvelope, EngineSupervisor, ObservedCommandEnvelope, OnionRotationProcess,
    QueueClass, QueuePressure, ReconnectProcess, SupervisorAction,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PipelineAdmission {
    pub observed: ObservedCommandEnvelope,
    pub route: CommandRoute,
    pub queue_class: QueueClass,
    pub decision: BackpressureDecision,
}

impl PipelineAdmission {
    pub const fn execute_immediately(&self) -> bool {
        matches!(self.decision, BackpressureDecision::Accept)
    }

    pub const fn persist_without_dispatch(&self) -> bool {
        matches!(self.decision, BackpressureDecision::PersistOnly)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineStabilizationPipeline {
    pub supervisor: EngineSupervisor,
    pub reconnect: ReconnectProcess,
    pub onion_rotation: OnionRotationProcess,
    pub backpressure: BackpressurePolicy,
}

impl Default for EngineStabilizationPipeline {
    fn default() -> Self {
        Self {
            supervisor: EngineSupervisor::default(),
            reconnect: ReconnectProcess::default(),
            onion_rotation: OnionRotationProcess::default(),
            backpressure: BackpressurePolicy::default(),
        }
    }
}

impl EngineStabilizationPipeline {
    pub fn start(&mut self) -> Vec<SupervisorAction> {
        self.supervisor.start_all()
    }

    pub fn admit(
        &self,
        envelope: EngineCommandEnvelope,
        pressure: QueuePressure,
    ) -> PipelineAdmission {
        let route = CommandRouter::route(&envelope.command);
        let queue_class = queue_class(route);
        let decision = self.backpressure.decide(queue_class, pressure);
        PipelineAdmission {
            observed: ObservedCommandEnvelope::from_legacy(envelope),
            route,
            queue_class,
            decision,
        }
    }
}

pub const fn queue_class(route: CommandRoute) -> QueueClass {
    match route.family {
        CommandFamily::Bootstrap | CommandFamily::Lifecycle => QueueClass::Critical,
        CommandFamily::Pairing => QueueClass::Pairing,
        CommandFamily::Messages if route.durable => QueueClass::Message,
        CommandFamily::Peer if route.durable => QueueClass::Endpoint,
        CommandFamily::Ephemeral => QueueClass::Ephemeral,
        CommandFamily::Profile
        | CommandFamily::Contacts
        | CommandFamily::Conversations
            if route.durable => QueueClass::Message,
        CommandFamily::Profile
        | CommandFamily::Contacts
        | CommandFamily::Conversations
        | CommandFamily::Messages
        | CommandFamily::Peer => QueueClass::Projection,
    }
}

#[cfg(test)]
mod tests {
    use crate::{EngineCommand, WorkerKind, COMMAND_CHANNEL_CAPACITY};

    use super::*;

    fn overloaded() -> QueuePressure {
        QueuePressure {
            command_depth: COMMAND_CHANNEL_CAPACITY,
            ..QueuePressure::default()
        }
    }

    #[test]
    fn overloaded_durable_message_is_persisted_not_dropped() {
        let pipeline = EngineStabilizationPipeline::default();
        let admission = pipeline.admit(
            EngineCommandEnvelope {
                request_id: "send".to_owned(),
                command: EngineCommand::SendMessage {
                    conversation_id: "conversation".to_owned(),
                    body: "hello".to_owned(),
                    reply_to_message_id: None,
                },
            },
            overloaded(),
        );

        assert_eq!(admission.queue_class, QueueClass::Message);
        assert!(admission.persist_without_dispatch());
        assert!(!admission.execute_immediately());
    }

    #[test]
    fn overloaded_typing_is_conflated() {
        let pipeline = EngineStabilizationPipeline::default();
        let admission = pipeline.admit(
            EngineCommandEnvelope {
                request_id: "typing".to_owned(),
                command: EngineCommand::SetTyping {
                    conversation_id: "conversation".to_owned(),
                    typing: true,
                },
            },
            overloaded(),
        );

        assert_eq!(admission.decision, BackpressureDecision::Conflate);
    }

    #[test]
    fn startup_is_supervised_for_every_registered_worker() {
        let mut pipeline = EngineStabilizationPipeline::default();
        let actions = pipeline.start();
        assert!(actions.iter().any(|action| matches!(
            action,
            SupervisorAction::StartWorker {
                worker: WorkerKind::State
            }
        )));
        assert!(actions.iter().any(|action| matches!(
            action,
            SupervisorAction::StartWorker {
                worker: WorkerKind::Delivery
            }
        )));
    }
}
