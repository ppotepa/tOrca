use std::fs;
use std::path::PathBuf;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn unified_input_contract_declares_correlation_and_causation_metadata() {
    let source = fs::read_to_string(crate_root().join("src/input.rs"))
        .expect("input contract source is readable");
    let derived = fs::read_to_string(crate_root().join("src/input_derived.rs"))
        .expect("derived input source is readable");

    for symbol in [
        "struct EngineInputEnvelope",
        "input_id: uuid::Uuid",
        "correlation_id: Option<String>",
        "causation_id: Option<uuid::Uuid>",
        "source: EngineInputSource",
        "enqueued_at_ms: i64",
        "enum EngineInput",
        "enum EngineTimerKind",
        "fn peer_event",
        "fn relay_event",
        "fn timer",
        "fn shutdown",
    ] {
        assert!(source.contains(symbol), "missing unified input symbol: {symbol}");
    }
    for symbol in [
        "fn relay_event_caused",
        "fn effect_outcome_correlated",
        "causation_id: Some(causation_id)",
        "correlation_id: Some(correlation_id)",
    ] {
        assert!(derived.contains(symbol), "missing derived input symbol: {symbol}");
    }
}

#[test]
fn processing_contract_keeps_outputs_explicit() {
    let source = fs::read_to_string(crate_root().join("src/processing.rs"))
        .expect("processing contract source is readable");

    for symbol in [
        "struct EngineProcessingResult",
        "events: Vec<EngineEvent>",
        "effects: Vec<EngineEffectEnvelope>",
        "derived_inputs: Vec<EngineInputEnvelope>",
        "scheduler_plan_changed: bool",
        "control: ProcessingControl",
        "struct EngineProcessingResultBuilder",
    ] {
        assert!(source.contains(symbol), "missing processing symbol: {symbol}");
    }
}

#[test]
fn client_commands_enter_the_unified_inbox_before_actor_dispatch() {
    let source = fs::read_to_string(crate_root().join("src/engine.rs"))
        .expect("engine source is readable");

    for symbol in [
        "struct EngineCommandSender",
        "mpsc::Sender<EngineInputEnvelope>",
        "EngineInputEnvelope::command",
        "fn unified_inbox_channel",
        "ENGINE_INBOX_CAPACITY",
        ".run_unified(",
        "EngineInputSource::ClientApi",
        "EngineInputSource::Ffi",
    ] {
        assert!(source.contains(symbol), "missing unified command ingress symbol: {symbol}");
    }

    assert!(
        !source.contains("commands: mpsc::Sender<EngineCommandEnvelope>"),
        "ClientEngine must not own the legacy raw command sender",
    );
    assert!(
        !source.contains("fn unified_command_channel"),
        "the temporary command-only forwarder must not return",
    );
    assert!(
        !source.contains("actor.run("),
        "ClientEngine must not reactivate the legacy multi-receiver actor loop",
    );
}

#[test]
fn active_actor_loop_has_exactly_one_state_mutating_receiver() {
    let source = fs::read_to_string(crate_root().join("src/actor/unified.rs"))
        .expect("unified actor source is readable");

    for symbol in [
        "pub async fn run_unified",
        "inbox.recv().await",
        "fn process_unified_input",
        "EngineInput::Command",
        "EngineInput::PeerEvent",
        "EngineInput::RelayEvent",
        "EngineInput::PlatformFact",
        "EngineInput::TimerElapsed",
        "EngineInput::EffectOutcome",
        "EngineInput::ShutdownRequested",
    ] {
        assert!(source.contains(symbol), "missing single-consumer symbol: {symbol}");
    }

    let loop_body = source
        .split("pub async fn run_unified")
        .nth(1)
        .expect("run_unified exists")
        .split("fn process_unified_input")
        .next()
        .expect("run_unified body exists");
    assert!(
        !loop_body.contains("tokio::select!"),
        "the state-owning actor loop must not arbitrate independent receivers",
    );
    assert!(!loop_body.contains("peer_events.recv()"));
    assert!(!loop_body.contains("sleep_until("));
}

#[test]
fn timers_are_external_inputs_with_generation_fencing() {
    let source = fs::read_to_string(crate_root().join("src/scheduler.rs"))
        .expect("scheduler source is readable");
    let actor = fs::read_to_string(crate_root().join("src/actor/unified.rs"))
        .expect("unified actor source is readable");

    for symbol in [
        "struct EngineSchedulerPlan",
        "generation: u64",
        "spawn_engine_scheduler",
        "EngineInputEnvelope::timer",
    ] {
        assert!(source.contains(symbol), "missing scheduler symbol: {symbol}");
    }
    assert!(actor.contains("generation != scheduler_generation"));
}

#[test]
fn relay_frames_become_inputs_before_state_mutation() {
    let host = fs::read_to_string(crate_root().join("src/actor/unified.rs"))
        .expect("unified actor source is readable");
    let handlers = fs::read_to_string(crate_root().join("src/actor/unified_handlers.rs"))
        .expect("unified handler source is readable");

    assert!(host.contains("derived_inputs.pop_front"));
    assert!(host.contains("derived_inputs.extend"));
    assert!(handlers.contains("result.derived_inputs.push"));
    assert!(handlers.contains("EngineInputEnvelope::relay_event_caused"));
    let relay_tick = handlers
        .split("EngineTimerKind::RelayPoll")
        .nth(1)
        .expect("relay timer exists")
        .split("EngineTimerKind::PeerProbeRound")
        .next()
        .expect("relay timer body exists");
    assert!(!relay_tick.contains("process_relay_input(event)"));
}

#[test]
fn blocking_rendezvous_operations_execute_outside_the_actor() {
    let commands = fs::read_to_string(crate_root().join("src/actor/unified_command.rs"))
        .expect("unified command source is readable");
    let host = fs::read_to_string(crate_root().join("src/actor/unified.rs"))
        .expect("unified actor source is readable");
    let worker = fs::read_to_string(crate_root().join("src/effects/relay.rs"))
        .expect("relay effect source is readable");

    for symbol in [
        "runtime.prepare_refresh_pairing_code()",
        "runtime.prepare_submit_pairing_code(code)",
        "runtime.prepare_cancel_pairing(&pairing_id)",
        "RelayEffectOperation::RefreshPairingCode",
        "RelayEffectOperation::SubmitPairingCode",
        "RelayEffectOperation::CancelPairing",
        "process_effect_outcome",
        "RelayEffectPlaceholder::default()",
        "take_deferred_control",
        "runtime.confirm_pairing_cancelled(&pairing_id)",
    ] {
        assert!(commands.contains(symbol), "missing actor effect boundary: {symbol}");
    }
    assert!(host.contains("spawn_engine_effect"));
    for symbol in [
        "tokio::task::spawn_blocking",
        "std::panic::catch_unwind",
        "RelayEffectResult::WorkerFailed",
        "EngineInputEnvelope::effect_outcome_correlated",
        "struct RelayEffectPlaceholder",
        "submit_pairing_code_with_offer",
    ] {
        assert!(worker.contains(symbol), "missing relay effect worker symbol: {symbol}");
    }

    assert!(!commands.contains("self.relay.refresh_pairing_code()"));
    assert!(!commands.contains("self.relay.submit_pairing_code_with_offer"));
    assert!(!commands.contains("self.relay.cancel_pairing"));
}

#[test]
fn response_resolution_is_not_blocked_by_public_event_backpressure() {
    let source = fs::read_to_string(crate_root().join("src/output.rs"))
        .expect("output source is readable");

    assert!(source.contains("mpsc::unbounded_channel"));
    assert!(source.contains("struct PendingResponseRegistry"));
    assert!(source.contains("fn fail_all"));
    let router = source
        .split("fn spawn_event_router")
        .nth(1)
        .expect("event router exists");
    let response_index = router
        .find("pending.complete")
        .expect("response is resolved");
    let publish_index = router
        .find("publish_tx.send(event)")
        .expect("event is queued for publishing");
    assert!(response_index < publish_index);
}

#[test]
fn flutter_does_not_reintroduce_a_platform_specific_command_queue() {
    let flutter = fs::read_to_string(
        crate_root().join("../../apps/mobile/flutter/lib/client_runtime.dart"),
    )
    .expect("flutter runtime source is readable");

    assert!(!flutter.contains("_SerializedClientRuntime"));
    assert!(!flutter.contains("Platform.isWindows"));
    assert!(flutter.contains("return _SessionAwareClientRuntime(platform);"));
}
