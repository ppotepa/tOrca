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

fn read_tree(path: &Path) -> String {
    rust_files_below(path)
        .into_iter()
        .map(read)
        .collect::<String>()
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
        assert!(
            exports.contains(symbol),
            "missing public re-export: {symbol}"
        );
    }
}

#[test]
fn unified_input_keeps_correlation_and_causation_metadata() {
    let input_root = crate_root().join("src/input");
    let input = read_tree(&input_root);
    for file in [
        "mod.rs",
        "envelope.rs",
        "source.rs",
        "timer.rs",
        "derived.rs",
    ] {
        assert!(
            input_root.join(file).is_file(),
            "missing input file: {file}"
        );
    }
    for symbol in [
        "struct EngineInputEnvelope",
        "input_id: uuid::Uuid",
        "correlation_id: Option<String>",
        "causation_id: Option<uuid::Uuid>",
        "enum EngineInput",
        "enum EngineTimerKind",
        "fn effect_outcome_correlated",
        "fn relay_event_caused",
    ] {
        assert!(input.contains(symbol), "missing input symbol: {symbol}");
    }
    let envelope = read(input_root.join("envelope.rs"));
    assert!(!envelope.contains("pub(crate) fn effect_outcome("));
    assert!(!crate_root().join("src/input.rs").exists());
    assert!(!crate_root().join("src/input_derived.rs").exists());
}

#[test]
fn engine_has_one_command_inbox_and_one_state_mutating_receiver() {
    let engine = read(crate_root().join("src/engine.rs"));
    let actor = read(crate_root().join("src/actor/run.rs"));

    assert!(engine.contains("mpsc::Sender<EngineInputEnvelope>"));
    assert!(engine.contains("fn engine_inbox_channel"));
    assert!(engine.contains(".run("));
    assert!(!engine.contains("commands: mpsc::Sender<EngineCommandEnvelope>"));
    assert!(!engine.contains("run_unified"));
    assert!(!engine.contains("unified_inbox_channel"));
    assert!(!engine.contains("COMMAND_CHANNEL_CAPACITY"));

    assert!(actor.contains("inbox.recv().await"));
    assert!(actor.contains("fn process_input"));
    let loop_body = actor
        .split("pub async fn run(")
        .nth(1)
        .expect("run exists")
        .split("fn process_input")
        .next()
        .expect("run loop body exists");
    assert!(!loop_body.contains("tokio::select!"));
    assert!(!loop_body.contains("peer_events.recv()"));
    assert!(!loop_body.contains("sleep_until("));
}

#[test]
fn actor_has_one_canonical_loop_and_no_transitional_source_files() {
    let actor_root = crate_root().join("src/actor");
    assert!(actor_root.join("state.rs").is_file());
    assert!(actor_root.join("run.rs").is_file());
    assert!(actor_root.join("input_handlers.rs").is_file());
    assert!(!actor_root.join("legacy.rs").exists());
    assert!(!actor_root.join("legacy").exists());
    assert!(!actor_root.join("unified.rs").exists());
    assert!(!actor_root.join("unified_handlers.rs").exists());

    let state = read(actor_root.join("state.rs"));
    let run = read(actor_root.join("run.rs"));
    assert!(!state.contains("pub async fn run("));
    assert!(run.contains("pub async fn run("));
}

#[test]
fn command_router_only_delegates() {
    let router = read(crate_root().join("src/actor/state/command_dispatch.rs"));
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
        assert!(
            !router.contains(forbidden),
            "router contains logic: {forbidden}"
        );
    }
}

#[test]
fn every_command_handler_is_small_and_does_not_publish_rpc_responses() {
    let files = rust_files_below(&crate_root().join("src/actor/commands"));
    assert!(files.len() >= 35, "expected granular command files");

    for path in files {
        let source = read(&path);
        assert!(
            !source.contains("EngineEvent::Response"),
            "{}",
            path.display()
        );
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
        assert!(
            processor.contains(symbol),
            "missing pipeline symbol: {symbol}"
        );
    }
    assert!(!crate_root().join("src/actor/unified_command.rs").exists());
}

#[test]
fn rendezvous_io_runs_only_in_the_split_effect_worker() {
    let pairing_sources = read_tree(&crate_root().join("src/actor/commands/pairing"));
    let preparation = read(crate_root().join("src/actor/command_pipeline/relay_effect.rs"));
    let worker = read(crate_root().join("src/effects/relay/worker.rs"));
    let placeholder = read(crate_root().join("src/effects/relay/placeholder.rs"));
    let outcome = read(crate_root().join("src/effects/relay/outcome.rs"));

    for symbol in [
        "prepare_refresh_code()",
        "runtime.prepare_submit_pairing_code(code)",
        "feature_prepare_cancel_pairing(&pairing_id)",
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
fn runtime_and_relay_expose_only_the_canonical_pairing_path() {
    let runtime_root = crate_root().join("../torchat-runtime/src");
    let runtime = read(runtime_root.join("runtime.rs"));
    let runtime_transport = read(runtime_root.join("transport.rs"));
    let relay = read(crate_root().join("src/relay/mod.rs"));

    assert!(!runtime.contains("pub fn set_nickname("));
    assert!(!runtime.contains("pub fn refresh_pairing_code("));
    assert!(!runtime.contains("pub fn submit_pairing_code("));
    assert!(!runtime_transport.contains("fn refresh_pairing_code("));
    assert!(!runtime_transport.contains("fn submit_pairing_code("));
    assert!(!runtime_transport.contains("fn pairing_inbox("));
    assert!(!relay.contains("fn submit_pairing_code(&mut self"));
    assert!(relay.contains("fn submit_pairing_code_with_offer("));
}

#[test]
fn timers_and_relay_frames_reenter_the_input_pipeline() {
    let scheduler_root = crate_root().join("src/scheduler");
    let scheduler = read_tree(&scheduler_root);
    let actor = read(crate_root().join("src/actor/run.rs"));
    let handlers = read(crate_root().join("src/actor/input_handlers.rs"));

    for file in ["mod.rs", "plan.rs", "worker.rs"] {
        assert!(
            scheduler_root.join(file).is_file(),
            "missing scheduler file: {file}"
        );
    }
    assert!(scheduler.contains("generation: u64"));
    assert!(scheduler.contains("EngineInputEnvelope::timer"));
    assert!(actor.contains("generation != scheduler_generation"));
    assert!(actor.contains("derived_inputs.pop_front"));
    assert!(handlers.contains("EngineInputEnvelope::relay_event_caused"));
    assert!(!crate_root().join("src/scheduler.rs").exists());
}

#[test]
fn response_resolution_precedes_public_event_backpressure() {
    let output_root = crate_root().join("src/output");
    for file in [
        "mod.rs",
        "event_router.rs",
        "publisher.rs",
        "response_registry.rs",
    ] {
        assert!(
            output_root.join(file).is_file(),
            "missing output file: {file}"
        );
    }
    let router = read(output_root.join("event_router.rs"));
    assert!(
        router
            .find("pending.complete")
            .expect("response completion exists")
            < router
                .find("publish_tx.send(event)")
                .expect("event publishing exists")
    );
    assert!(!crate_root().join("src/output.rs").exists());
}

#[test]
fn dead_code_is_not_suppressed_and_unused_builder_is_absent() {
    let lib = read(crate_root().join("src/lib.rs"));
    let processing = read(crate_root().join("src/processing.rs"));
    assert!(!lib.contains("allow(dead_code)"));
    assert!(!processing.contains("EngineProcessingResultBuilder"));
}

#[test]
fn platform_specific_command_queue_is_absent() {
    let flutter = read(crate_root().join("../../apps/mobile/flutter/lib/client_runtime.dart"));
    assert!(!flutter.contains("_SerializedClientRuntime"));
    assert!(!flutter.contains("Platform.isWindows"));
}
