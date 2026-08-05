use std::fs;
use std::path::{Path, PathBuf};

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn rust_files_below(path: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(path).expect("source directory is readable") {
        let path = entry.expect("directory entry is readable").path();
        if path.is_dir() {
            files.extend(rust_files_below(&path));
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            files.push(path);
        }
    }
    files
}

fn read(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path).expect("source file is readable")
}

#[test]
fn command_contract_is_split_without_changing_public_types() {
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

    let exports = read(crate_root().join("src/lib.rs"));
    for symbol in [
        "EngineCommand",
        "EngineCommandEnvelope",
        "PlatformFact",
        "PlatformKind",
        "TorPhase",
    ] {
        assert!(exports.contains(symbol), "missing public re-export: {symbol}");
    }
}

#[test]
fn unified_input_keeps_correlation_and_causation_metadata() {
    let input = read(crate_root().join("src/input.rs"));
    let derived = read(crate_root().join("src/input_derived.rs"));
    for symbol in [
        "struct EngineInputEnvelope",
        "input_id: uuid::Uuid",
        "correlation_id: Option<String>",
        "causation_id: Option<uuid::Uuid>",
        "enum EngineInput",
        "enum EngineTimerKind",
    ] {
        assert!(input.contains(symbol), "missing input symbol: {symbol}");
    }
    assert!(derived.contains("fn effect_outcome_correlated"));
    assert!(derived.contains("fn relay_event_caused"));
}

#[test]
fn engine_has_one_command_inbox_and_one_state_mutating_receiver() {
    let engine = read(crate_root().join("src/engine.rs"));
    let actor = read(crate_root().join("src/actor/unified.rs"));

    assert!(engine.contains("mpsc::Sender<EngineInputEnvelope>"));
    assert!(engine.contains("fn unified_inbox_channel"));
    assert!(engine.contains(".run_unified("));
    assert!(!engine.contains("commands: mpsc::Sender<EngineCommandEnvelope>"));
    assert!(!engine.contains("actor.run("));

    assert!(actor.contains("inbox.recv().await"));
    assert!(actor.contains("fn process_unified_input"));
    let loop_body = actor
        .split("pub async fn run_unified")
        .nth(1)
        .expect("run_unified exists")
        .split("fn process_unified_input")
        .next()
        .expect("run loop body exists");
    assert!(!loop_body.contains("tokio::select!"));
    assert!(!loop_body.contains("peer_events.recv()"));
    assert!(!loop_body.contains("sleep_until("));
}

#[test]
fn command_router_only_delegates() {
    let router = read(crate_root().join("src/actor/command_dispatch.rs"));
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
fn every_command_handler_is_small_and_does_not_publish_rpc_responses() {
    let files = rust_files_below(&crate_root().join("src/actor/commands"));
    assert!(files.len() >= 35, "expected granular command files");

    for path in files {
        let source = read(&path);
        assert!(!source.contains("EngineEvent::Response"), "{}", path.display());
        assert!(!source.contains("spawn_blocking"), "{}", path.display());
    }
}

#[test]
fn command_pipeline_owns_idempotency_responses_and_effect_outcomes() {
    let processor = read(crate_root().join("src/actor/command_pipeline/processor.rs"));
    for symbol in [
        "load_processed_command",
        "save_processed_command",
        "EngineEvent::Response",
        "process_effect_outcome",
        "take_deferred_control",
        "command_error_result",
    ] {
        assert!(processor.contains(symbol), "missing pipeline symbol: {symbol}");
    }
    assert!(!crate_root().join("src/actor/unified_command.rs").exists());
}

#[test]
fn rendezvous_io_runs_only_in_the_split_effect_worker() {
    let pairing_sources = rust_files_below(&crate_root().join("src/actor/commands/pairing"))
        .into_iter()
        .map(read)
        .collect::<String>();
    let preparation = read(crate_root().join("src/actor/command_pipeline/relay_effect.rs"));
    let worker = read(crate_root().join("src/effects/relay/worker.rs"));
    let placeholder = read(crate_root().join("src/effects/relay/placeholder.rs"));
    let outcome = read(crate_root().join("src/effects/relay/outcome.rs"));

    for symbol in [
        "runtime.prepare_refresh_pairing_code()",
        "runtime.prepare_submit_pairing_code(code)",
        "runtime.prepare_cancel_pairing(&pairing_id)",
    ] {
        assert!(pairing_sources.contains(symbol) || preparation.contains(symbol));
    }
    assert!(worker.contains("tokio::task::spawn_blocking"));
    assert!(worker.contains("std::panic::catch_unwind"));
    assert!(worker.contains("submit_pairing_code_with_offer"));
    assert!(placeholder.contains("struct RelayEffectPlaceholder"));
    assert!(outcome.contains("RelayEffectResult"));
    assert!(!pairing_sources.contains("self.relay.refresh_pairing_code()"));
    assert!(!pairing_sources.contains("self.relay.submit_pairing_code_with_offer"));
    assert!(!pairing_sources.contains("self.relay.cancel_pairing"));
    assert!(!crate_root().join("src/effects/relay.rs").exists());
}

#[test]
fn timers_and_relay_frames_reenter_the_unified_input_pipeline() {
    let scheduler = read(crate_root().join("src/scheduler.rs"));
    let actor = read(crate_root().join("src/actor/unified.rs"));
    let handlers = read(crate_root().join("src/actor/unified_handlers.rs"));

    assert!(scheduler.contains("generation: u64"));
    assert!(scheduler.contains("EngineInputEnvelope::timer"));
    assert!(actor.contains("generation != scheduler_generation"));
    assert!(actor.contains("derived_inputs.pop_front"));
    assert!(handlers.contains("EngineInputEnvelope::relay_event_caused"));
}

#[test]
fn response_resolution_precedes_public_event_backpressure() {
    let output = read(crate_root().join("src/output.rs"));
    let router = output
        .split("fn spawn_event_router")
        .nth(1)
        .expect("event router exists");
    assert!(router.find("pending.complete").expect("response completion exists")
        < router.find("publish_tx.send(event)").expect("event publishing exists"));
}

#[test]
fn dead_legacy_snapshot_and_platform_specific_queue_are_absent() {
    assert!(!crate_root().join("src/actor/legacy").exists());
    let flutter = read(crate_root().join("../../apps/mobile/flutter/lib/client_runtime.dart"));
    assert!(!flutter.contains("_SerializedClientRuntime"));
    assert!(!flutter.contains("Platform.isWindows"));
}
