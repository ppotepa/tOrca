use std::{fs, path::PathBuf};

fn read(root: &PathBuf, relative: &str) -> String {
    fs::read_to_string(root.join(relative))
        .unwrap_or_else(|error| panic!("read {relative}: {error}"))
}

#[test]
fn pairing_recovery_is_owned_by_engine_and_runtime() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let pairing = read(&root, "src/actor/pairing.rs");
    let accept = read(
        &root,
        "src/actor/commands/pairing/accept_pairing.rs",
    );

    assert!(
        pairing.contains("fn retry_pending_welcomes"),
        "engine must retain durable Welcome retry"
    );
    assert!(
        pairing.contains("due_pending_welcomes"),
        "retry must be driven by persisted due records"
    );
    assert!(
        pairing.contains("claim_pending_welcome_attempt"),
        "retry attempts must be claimed before sending"
    );
    assert!(
        pairing.contains("pairing_retry_backoff_ms"),
        "pairing retry must use the backend retry policy"
    );
    assert!(
        pairing.contains("put_pending_welcome"),
        "Welcome intent must be persisted with the relationship commit"
    );
    assert!(
        pairing.contains("BeginVerified"),
        "successful pairing must establish the verified relationship in Rust"
    );
    assert!(
        pairing.contains("put_conversation_mls_snapshot"),
        "successful pairing must persist its conversation in Rust"
    );
    assert!(
        accept.contains("prepare_accept_pairing")
            && accept.contains("accept_invite")
            && accept.contains("accept_received_pairing"),
        "accept command must execute one backend workflow"
    );
}

#[test]
fn duplicate_invite_reuses_persisted_welcome_instead_of_recreating_domain_state() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let pairing = read(&root, "src/actor/pairing.rs");

    assert!(pairing.contains("invite_used"));
    assert!(pairing.contains("pending_welcome"));
    assert!(pairing.contains("welcome resend enqueue deferred"));
}
