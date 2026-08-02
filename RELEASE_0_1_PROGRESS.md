# TorChat 0.1 - implementation progress

This is the single maintained tracker for finalizing TorChat 0.1. It records
implemented work, remaining work, verification and release blockers. Do not
create parallel status documents.

## Current completion

**Code cleanup: 100% | Manual release validation: pending**

The code percentage covers production implementation only. Manual Tor/P2P
validation and externally supplied Android signing credentials are tracked
separately and are intentionally not part of this code-only pass.

## P0 - correctness and availability

- [x] **P0-01 Relay effects outside SQLite transactions and actor waits**
  - `common/torchat-client-engine/src/actor.rs`
  - `common/torchat-client-engine/src/relay/{mod.rs,actor.rs}`
  - Prepare local state in a transaction, execute the network effect outside
    `RuntimeSession`, then atomically apply an idempotent outcome.
  - Implemented 2026-08-02: profile update, pairing-code refresh, pairing-code
    submission and pairing-inbox fetch now run through a serialized
    `spawn_blocking` relay-control worker; only their local prepare/commit
    phases run on the actor transaction. Bootstrap no longer repeats profile
    HTTP after reconnect. Relay-session bootstrap itself is generation-checked
    and worker-backed. Acknowledgement and contact-confirmation HTTP now use
    the same serialized worker and complete their durable pending rows only
    after a successful network outcome; duplicate inbox, acknowledgement and
    confirmation effects are coalesced before entering the worker. Automated tests are intentionally
    deferred per the current implementation scope; manual validation remains
    the release check.
- [x] **P0-02 Retry scheduler cannot spin while blocked**
  - `common/torchat-client-engine/src/actor.rs`
  - Implemented 2026-08-02: retry eligibility gates deadlines before they
    reach `sleep_until`; blocked work uses bounded 5 s / offline 30 s rechecks.
    Engine library and delivery-resilience tests pass.
- [x] **P0-03 Relay polling uses a stable deadline**
  - `common/torchat-client-engine/src/actor.rs`
  - Implemented 2026-08-02: `relay_poll_at` is actor state and advances only
    after `drain_relay_events`. Engine library tests passed (61).
- [x] **P0-04 Verified re-pair clears relationship tombstones atomically**
  - `common/torchat-client-engine/src/{actor.rs,storage/runtime_storage.rs}`
  - Implemented 2026-08-02: verified pairing clears the tombstone and creates
    a relationship boundary immediately before persisting the fresh MLS state,
    in the existing runtime transaction. Focused removal and engine tests pass.
- [x] **P0-05 Readiness components are distinct**
  - `common/client-engine-contract.json`, Android bridge, desktop bridge,
    `mobile/lib/core/connection/`
  - Implemented 2026-08-02: Android maps relay connection snapshots to
    `transport_status_changed(component=relay)` instead of overwriting Tor
    bootstrap state. Flutter readiness tests and an Android debug build pass.
- [x] **P0-06 Unsupported ephemeral signals never return false success**
  - Implemented 2026-08-02: typing, presence and read receipts return
    `unsupported` while MLS delivery is lossy for those frames. Opening a
    conversation no longer submits read receipts. Engine and focused Flutter
    checks pass.
- [x] **P0-07 Source encoding audit**
  - `scripts/internal/check-text-encoding.ps1`
  - Implemented 2026-08-02: strict UTF-8 validation rejects replacement and
    known UTF-8/legacy-codepage mojibake markers across source and release
    documentation.

## P1 - active architecture and consistency

- [x] **P1-01 Remove or privatize disconnected engine modules**
  - Audit `application`, `delivery`, `domain`, `inbound`, `projections`,
    `idempotency`, `observability`, `backpressure` with CodeGraph first.
  - Implemented 2026-08-02: CodeGraph found no production callers for the
    alternative routers, schedulers, pipeline, projections or observability
    stack. Their exports and source were removed, leaving the active actor,
    runtime, storage, relay and peer path. Engine/FFI tests and desktop check
    pass.
- [x] **P1-02 Split ClientEngineActor by responsibility without another actor**
  - Implemented 2026-08-02: connection lifecycle, retry scheduling and relay
    bootstrap handling now live in `src/actor/connection.rs`; the existing
    `ClientEngineActor` remains the sole owner of state and event loop.
    `cargo fmt`, engine check and 45 focused engine tests pass.
- [x] **P1-03 Projection revisions advance only after visible persistent writes**
  - Separate read and write runtime helpers.
  - Implemented 2026-08-02: `RuntimeSession` classifies staged domain events;
    actor transactions bump the durable projection revision only for events
    that alter visible persisted application/conversation state. Transport,
    Tor and ephemeral events do not create false refreshes. Runtime and engine
    tests pass. The Flutter repository now requires the typed atomic
    `RuntimeProjectionProvider`; the old multi-call compatibility fallback was
    removed so production cannot recreate mixed identity/contact/conversation
    snapshots. Older-message pagination is also applied through
    `RuntimeRepository`, not by UI controllers mutating the projection store.
    `AppState` now renders identity, profile, contacts and conversations from
    the latest atomic projection instead of reading those domains from the
    mutable singleton during every getter call. Pairing inbox/outbox lists
    are also copied from the repository-owned pairing snapshot during refresh,
    so acceptance UI no longer depends on a hidden singleton read.
- [x] **P1-04 Mutating command idempotency is atomic and validates type/payload**
  - Partial 2026-08-02: replay now validates a descriptor derived from the
    command type and full serialized payload, corrupt stored results return an
    explicit error, and the result is persisted before its response event. The
    command-result persistence now runs in the active `SqliteRuntimeStorage`
    transaction for the final commit of profile, pairing, contact,
    conversation and message mutations. Transport-only retry commands do not
    create a separate durable domain mutation. Implemented 2026-08-02:
    `command_idempotency.rs`
    runs a real `ClientEngine`, replays the same bootstrap `command_id`, then
    reopens SQLite and verifies its single durable, valid response result.
- [x] **P1-05 One payload limit across peer and relay transports**
  - Implemented 2026-08-02: `MAX_TRANSPORT_CIPHERTEXT_BYTES` is owned by
    `torchat-core` and used by peer delivery and relay validation. Core/engine
    tests and server compilation pass.
- [x] **P1-06 FFI polling cannot block command submission**
  - Implemented 2026-08-02: the FFI handle has separately locked event and
    command/lifecycle state. `poll_json` no longer blocks submission, and FFI
    preserves supplied `command_id`. FFI tests passed (3).

## P1 - privacy and service hardening

- [x] **P1-07 Zeroize secrets and retain only non-secret engine configuration**
  - Implemented 2026-08-02: `SecretBytes` zeroizes its owned bytes on drop,
    and `ClientEngineActor` retains only `PlatformKind` after initialization,
    not a second long-lived `EngineConfig` copy of database and identity keys.
    Engine library tests passed (62).
- [x] **P1-08 Persistent diagnostics use session-local pseudonyms by default**
  - Implemented 2026-08-02: startup journals replace known contact, message,
    pairing and conversation identifiers with deterministic per-session hashes;
    onion addresses remain redacted. Engine library tests passed (62).
- [x] **P1-09 Server bootstrap and pairing endpoints are bounded and rate-limited**
  - Implemented 2026-08-02: unauthenticated bootstrap challenge storage is
    capped at 10,000 live entries and JSON bodies at 16 KiB. Existing pairing
    attempt limits remain in force. Server tests passed (13).

## Release gates

- [x] **RG-01 Full workspace format, check, clippy and test gate**
  - Verified 2026-08-02: `cargo fmt --all -- --check`, `cargo check
    --workspace`, `cargo clippy --workspace --all-targets -- -D warnings` and
    `cargo test --workspace` all pass (183 tests). The GitHub Actions Rust
    job now executes these workspace-wide gates instead of only runtime and
    engine subsets.
- [x] **RG-02 Android symbols, contract, schema, architecture and encoding checks**
  - Verified 2026-08-02: clean architecture, generated contract, SQL isolation,
    strict encoding and final Android engine ABI-symbol checks all pass. The
    encoding check is also installed in the CI Rust job.
- [ ] **RG-03 Two-real-engine Tor integration scenario**
  - Implemented harness 2026-08-02: the opt-in `torka-integration` Compose profile
    creates a separate identity and Tor data directory, pairs with the
    persistent Torka peer, requires an authenticated direct peer session and
    verifies normal encrypted `ping` -> `pong` delivery. The finite probe is
    driven by `scripts/tests/Test-TorChatTwoEngineIntegration.ps1` and is a
    mainline GitHub Actions gate. The local full probe currently exposes
    transient relay-bootstrap/backoff during the second peer's first profile
    update; it must complete successfully and be observed on CI before this
    release gate may be marked complete.
- [ ] **RG-04 Android release signing and backup/export hardening**
  - Partial 2026-08-02: manifest disables backup; release builds now require
    the four `TORCHAT_RELEASE_*` signing environment variables and never fall
    back to the debug certificate. Release cleartext is disabled and shrinking
    enabled. A manually dispatched GitHub Actions release job materializes an
    ephemeral base64 keystore, verifies the certificate and archives the APK
    with SHA-256. A debug Android build passes; a signed release build remains
    intentionally unverifiable until CI/product signing credentials exist.
- [x] **RG-05 User-facing diagnostic and deployment runbook**
  - Verified 2026-08-02: `scripts/README.md` documents the one public
    `scripts/torchat.ps1` entrypoint, deploy/run/reset policies, Android
    device selection, readiness meanings, run-log locations and diagnostics
    export. It explicitly separates routine deploys from destructive resets.

## Required end-to-end acceptance scenarios

The current implementation scope intentionally leaves these as manual checks;
they are not used to block the clean-code completion percentage.

- [ ] Queue text offline, restore connectivity and receive it exactly once.
- [ ] Restart at `QUEUED`, `SENDING` and `SENT` without losing delivery.
- [ ] Remove relationship, restart, re-pair, restart, then exchange text/image.
- [ ] P2P-only never sends message payload through relay.
- [ ] Explicit relay fallback avoids duplicate delivery.
- [ ] Tor/relay restart never blocks local profile, contact or chat reads.
- [ ] Android and Windows present the same readiness meaning.
- [ ] Exported logs contain neither plaintext nor keys nor stable contact ids.
