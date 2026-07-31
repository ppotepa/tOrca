use torchat_client_engine::{
    BackpressureDecision, EngineCommand, EngineCommandEnvelope, EngineStabilizationPipeline,
    QueuePressure, ReconnectApply, ReconnectEvent, SupervisorAction, WorkerKind,
    COMMAND_CHANNEL_CAPACITY,
};

#[test]
fn public_stabilization_pipeline_preserves_durable_commands_under_pressure() {
    let pipeline = EngineStabilizationPipeline::default();
    let admission = pipeline.admit(
        EngineCommandEnvelope {
            request_id: "send-message".to_owned(),
            command: EngineCommand::SendMessage {
                conversation_id: "conversation".to_owned(),
                body: "hello".to_owned(),
                reply_to_message_id: None,
            },
        },
        QueuePressure {
            command_depth: COMMAND_CHANNEL_CAPACITY,
            ..QueuePressure::default()
        },
    );

    assert_eq!(admission.decision, BackpressureDecision::PersistOnly);
    assert_eq!(
        admission.observed.metadata.command_id,
        admission.observed.metadata.correlation_id
    );
}

#[test]
fn supervisor_and_reconnect_process_are_available_through_one_pipeline() {
    let mut pipeline = EngineStabilizationPipeline::default();
    let starts = pipeline.start();
    assert!(starts.iter().any(|action| matches!(
        action,
        SupervisorAction::StartWorker {
            worker: WorkerKind::State
        }
    )));

    pipeline.reconnect.apply(ReconnectEvent::NetworkAvailable, 0);
    let reconnect = pipeline.reconnect.apply(ReconnectEvent::TorAvailable, 0);
    assert!(matches!(reconnect, ReconnectApply::Applied(_)));
}
