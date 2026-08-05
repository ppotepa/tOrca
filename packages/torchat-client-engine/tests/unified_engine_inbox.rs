use std::fs;
use std::path::{Path, PathBuf};

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn rust_files_below(path: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(path).expect("command directory is readable") {
        let entry = entry.expect("directory entry is readable");
        let path = entry.path();
        if path.is_dir() {
            files.extend(rust_files_below(&path));
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            files.push(path);
        }
    }
    files
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
    ] {
        assert!(source.contains(symbol), "missing processing symbol: {symbol}");
    }
}

#[test]
fn command_contract_is_split_from_platform_contracts() {
    let root = crate_root().join("src/contract");
    for file in [
        "command.rs",
        "command_envelope.rs",
        "platform_fact.rs",
        "platform_kind.rs",
        "tor_phase.rs",
    ] {
        assert!(root.join(file).is_file(), "missing contract file: {file}");
    }
    assert!(!crate_root().join("src/command.rs").exists());
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
    assert!(!source.contains("commands: mpsc::Sender<EngineCommandEnvelope>"));
    assert!(!source.contains("fn unified_command_channel"));
    assert!(!source.contains("actor.run("));
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
    assert!(!loop_body.contains("tokio::select!"));
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
fn command_router_only_delegates() {
    let router = fs::read_to_string(crate_root().join("src/actor/command_dispatch.rs"))
        .expect("command router is readable");

    assert!(router.contains("match command"));
    assert!(router.contains("self.command_send_message"));
    for forbidden in [
        "with_runtime(",
        "with_runtime_idempotent(",
        "self.database.",
        "self.relay.",
        "pending_engine_events.push",
        "EngineEvent::Response",
    ] {
        assert!(!router.contains(forbidden), "router contains logic: {forbidden}");
    }
}

#[test]
fn command_handlers_are_granular_and_do_not_publish_rpc_responses() {
    let root = crate_root().join("src/actor/commands");
    let files = rust_files_below(&root);
    assert!(files.len() >= 35, "expected granular command files, found {}", files.len());

    for path in files {
        let source = fs::read_to_string(&path).expect("command handler is readable");
        assert!(
            !source.contains("EngineEvent::Response"),
            "handler publishes RPC response: {}",
            path.display(),
        );
        assert!(
            !source.contains("spawn_blocking"),
            "handler executes worker directly: {}",
            path.display(),
        );
    }
}

#[test]
fn blocking_rendezvous_operations_execute_outside_the_actor() {
    let processor = fs::read_to_string(
        crate_root().join("src/actor/command_pipeline/processor.rs"),
    )
    .expect("command processor is readable");
    let relay_effect = fs::read_to_string(
        crate_root().join("src/actor/command_pipeline/relay_effect.rs"),
    )
    .expect("relay effect preparation is readable");
    let pairing_root = crate_root().join("src/actor/commands/pairing");
    let pairing_sources = rust_files_below(&pairing_root)
        .into_iter()
        .map(|path| fs::read_to_string(path).expect("pairing command is readable"))
        .collect::<String>();
    let host = fs::read_to_string(crate_root().join("src/actor/unified.rs"))
        .expect("unified actor source is readable");
    let worker = fs::read_to_string(crate_root().join("src/effects/relay.rs"))
        .expect("relay effect source is readable");

    for symbol in [
        "runtime.prepare_refresh_pairing_code()",
        "runtime.prepare_submit_pairing_code(code)",
        "runtime.prepare_cancel_pairing(&pairing_id)",
        "RelayEffectOperation::RefreshPairingCode",
        "RelayEffectOperation::CancelPairing",
    ] {
        assert!(
            pairing_sources.contains(symbol) || relay_effect.contains(symbol),
            "missing pairing effect boundary: {symbol}",
        );
    }
    assert!(processor.contains("process_effect_outcome"));
    assert!(processor.contains("take_deferred_control"));
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
    assert!(!pairing_sources.contains("self.relay.refresh_pairing_code()"));
    assert!(!pairing_sources.contains("self.relay.submit_pairing_code_with_offer"));
    assert!(!pairing_sources.contains("self.relay.cancel_pairing"));
    assert!(!crate_root().join("src/actor/unified_command.rs").exists());
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
    assert!(router.find("pending.complete").expect("response resolution exists")
        < router.find("publish_tx.send(event)").expect("event publishing exists"));
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
