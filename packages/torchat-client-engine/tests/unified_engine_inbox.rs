use std::fs;
use std::path::PathBuf;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn unified_input_contract_declares_correlation_and_causation_metadata() {
    let source = fs::read_to_string(crate_root().join("src/input.rs"))
        .expect("input contract source is readable");

    for symbol in [
        "struct EngineInputEnvelope",
        "input_id: uuid::Uuid",
        "correlation_id: Option<String>",
        "causation_id: Option<uuid::Uuid>",
        "source: EngineInputSource",
        "enqueued_at_ms: i64",
        "enum EngineInput",
        "enum EngineTimerKind",
    ] {
        assert!(source.contains(symbol), "missing unified input symbol: {symbol}");
    }
}

#[test]
fn processing_contract_keeps_outputs_explicit() {
    let source = fs::read_to_string(crate_root().join("src/processing.rs"))
        .expect("processing contract source is readable");

    for symbol in [
        "struct EngineProcessingResult",
        "events: Vec<EngineEvent>",
        "scheduler_plan_changed: bool",
        "control: ProcessingControl",
        "struct EngineProcessingResultBuilder",
    ] {
        assert!(source.contains(symbol), "missing processing symbol: {symbol}");
    }
}
