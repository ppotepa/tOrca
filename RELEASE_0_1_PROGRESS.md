# TorChat 0.1 - implementation progress

This is the single maintained tracker for finalizing TorChat 0.1. It records
implemented work, remaining work, verification and release blockers. Do not
create parallel status documents.

The post-stabilization structural modularization is tracked separately in
`REFACTOR_PROGRESS.md`; release correctness remains authoritative here.

## Current completion

**Code cleanup: 100% | Manual release validation: pending**

The code percentage covers production implementation only. Manual Tor/P2P
validation and externally supplied Android signing credentials are tracked
separately and are intentionally not part of this code-only pass.

## Endpoint capability hardening

- [x] Per-contact capability records with 16-character public IDs and
  SQLCipher-protected secret material (`018_contact_endpoint_capabilities.sql`).
- [x] Peer endpoint bundles carry the contact-scoped capability marker and
  authenticated handshake transcripts include the capability ID.
- [x] MLS-encrypted `CapabilityOffer` is emitted after a contact conversation
  is committed; the receiver validates and stores the peer secret in the
  separate `019_peer_endpoint_capabilities.sql` table and sends an encrypted
  acknowledgement.
- [x] Public engine commands and generated Dart/Kotlin/Windows mappings for
  get, rotate and revoke capability.
- [x] Contact details UI displays capability status/ID/sequence and provides
  rotate/revoke actions.
- [x] Add proof-of-possession HMAC to the peer hello. The receiver verifies
  the HMAC against the locally issued contact grant and rejects missing or
  invalid proof; there is no unauthenticated P2P bootstrap window.
- [x] Keep inbound and outbound grants directionally separate: inbound uses
  the local capability ID/secret, outbound uses the remote endpoint marker
  and the secret received from that peer.
- [x] Bootstrap capability control frames as opaque MLS ciphertext through
  relay even for `PeerOnly`, before opening the capability-protected P2P
  session. Relay readiness is checked before advancing the MLS ratchet and a
  failed enqueue restores both the in-memory and persisted MLS snapshot.
- [x] Retry missing capability offers after relay recovery and local onion
  readiness; receiving a capability immediately wakes an authenticated probe.

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

## Android Tor startup hardening

- [x] Log control-socket probe failures instead of silently reporting fake `0%` bootstrap.
- [x] Preserve `TOR_READY` as pending across transient bootstrap timeouts.
- [x] Retry native Tor startup with bounded backoff while keeping the Rust engine and local data alive.
- [x] Prevent retry attempts from publishing relay/onion readiness before Tor reaches bootstrap completion.
- [ ] Verify on-device recovery after Wi-Fi/LTE loss and a cold Tor start.

## Android background reattach status

- [x] Map Android relay connection phases to the canonical `TransportProbeState`
  values consumed by Flutter (`READY`, `STARTING`, `DEGRADED`, `OFFLINE`, `ERROR`).
- [x] Keep one latest Tor/relay status per component for Activity reattach
  instead of replaying stale status history as current readiness.
- [x] Reset retained status snapshots when the service generation stops.
- [ ] Verify minimize, resume and process recreation on a physical Android device.

## Repository cleanup

- [x] Removed 19 physically empty legacy/source placeholder directories after
  verifying that none contained tracked files or build inputs.
- [x] Removed the stale Android `arm64-v8a.corrupt-20260729` directory.
- [x] Removed the remaining empty source/temp leftovers (`.agents`, `docs`,
  `tests`, `mobile/src`, `mobile/mobile/assets/audio`, stale Flutter ephemeral
  links and `.tmp-javap` fragments) after verifying they contained no files.
- [ ] Audit non-empty but unreachable legacy files separately; this cleanup did
  not remove any file based only on a name or directory location.

## Pairing-to-conversation projection

- [x] `verify_contact` now creates an empty active conversation when pairing did
  not create one earlier, so Android and Windows publish the chat entry before
  the first message.
- [x] Preserve an existing conversation summary while promoting it to `Active`.
- [x] Add runtime regression coverage for verification without a conversation row.
- [ ] Verify the contact and empty chat entry on both platforms after a fresh pairing deploy.

## Live conversation projection

- [x] Remove frozen visible message limit from the active chat
- [x] Remove active-chat local pagination from the live timeline
- [x] Add stable message keys
- [x] Serialize read-your-writes refresh through `RuntimeRepository.sendMessage`
- [x] Add projection count/sequence diagnostics
- [x] Keep one keyed in-flight/trailing refresh per conversation
- [ ] Reduce broad application refreshes after message events
- [x] Isolate live message/status animations with repaint boundaries
- [x] Add open-chat live-history regression test
- [ ] Verify Android ↔ desktop live conversation after fresh deploy

## Responsive navigation and Android back

- [x] Keep the compact/mobile conversation list visible when the desktop
  sidebar is not mounted.
- [x] Add a regression test for the chat list at a 360 px viewport width.
- [x] Intercept Android system back while a conversation is open and return to
  the chat list before allowing the activity to background.
- [x] Return from Contacts/other top-level destinations to Chats before
  leaving the application.
- [x] Preserve native Android backgrounding only at the root of the app.
- [ ] Verify gesture back, three-button back and Activity recreation on a
  physical Android device.

## Chat layout polish

- [x] Increase the expanded desktop rail width so navigation labels are not
  clipped in narrow workspaces.
- [x] Keep the active chat at the bottom when new messages arrive while the
  user is already near the end of the timeline.
- [x] Show an explicit "new messages / scroll to bottom" action when the user
  is reading older messages.
- [x] Limit rendered image thumbnails to a 200 px maximum edge while keeping
  the full-resolution preview available on tap.

## QoL batch: composer and timeline

- [x] Selecting images creates a composer draft instead of sending immediately.
- [x] Support up to four prepared image attachments with per-item removal.
- [x] Send caption and images sequentially through the existing message path.
- [x] Add older-message loading near the top of the timeline with offset
  preservation and a busy indicator.
- [x] Keep the timeline cache close to the viewport so image bubbles are
  materialized lazily by the list builder.
- [ ] Persist unfinished attachment drafts across an application restart.

## Centralized probing

- [x] Add a reusable Rust `ProbeCoordinator` with shared probe kinds,
  per-target state, in-flight deduplication and exponential backoff.
- [x] Move peer probe scheduling ownership into `ClientEngineActor` instead of
  maintaining a standalone peer-probe deadline.
- [x] Feed peer connection results into the coordinator so all peer checks use
  the same `Unknown/Checking/Online/Offline` semantics.
- [ ] Expose the coordinator snapshot as a generated runtime event for the
  Flutter contact list, conversation header and connection panel.
- [ ] Add relay, onion-service and engine probes to the same coordinator.

## Contact presence and control frames

- [x] Add authenticated peer control frames for presence, typing and probe
  response without advancing the MLS ratchet.
- [x] Route lifecycle presence and typing commands through the peer transport
  instead of the disabled MLS ephemeral path.
- [x] Preserve observed presence timestamps in the Flutter session state and
  show `ostatnio widziany` in the active conversation header.
- [x] Persist presence timestamps in the canonical contact projection and expose
  them through `ContactRecord.lastSeenAt`.
- [ ] Add full relay/onion/engine probe snapshots to the generated contract.
- [x] Add privacy controls for presence, typing and last-seen visibility.
- [x] Send periodic authenticated presence heartbeats from the engine probe
  cadence, respecting foreground/background availability.

## Per-contact P2P capabilities

- [x] Generate and persist a separate 16-character capability ID per contact.
- [x] Attach the signed capability marker to endpoint bootstrap bundles.
- [x] Require the capability ID during authenticated inbound peer handshake.
- [x] Add migration 018 and engine-side capability storage/revocation hooks.
- [x] Exchange a private capability secret inside the post-pairing MLS payload.
- [x] Add user-facing capability rotation/revocation commands to the generated
  contract.

## Pairing and P2P bootstrap hardening

- [x] Keep pairing refresh requests pending through startup warmup; an invite
  event can no longer be replaced by a generic post-warmup refresh.
- [x] Remove the stale `ApplicationStateStore` fallback for pairing inbox and
  outbox projections, so an authoritative empty result cannot resurrect an
  acknowledged or expired invite.
- [x] Expire locally persisted invitations on the engine probe cadence even
  when relay connectivity is unavailable.
- [x] Buffer MLS application envelopes received before Welcome and replay them
  after the contact conversation is committed.
- [x] Ensure a local per-contact capability exists before endpoint
  authorization, including startup and endpoint rotation paths.
- [x] Emit diagnostics when symmetric capability offers or acknowledgements
  are deferred instead of silently discarding the error.
- [x] Invalidate cached relay sessions after HTTP 401 and force a fresh
  challenge/register bootstrap.
- [x] Replace in-memory pre-Welcome buffering with a durable encrypted inbox
  for process-crash recovery (MLS ciphertext remains opaque to storage).
- [x] Move capability offers/ACKs into a durable per-contact outbox with retry
  state and replay after relay reconnect or engine restart.
- [ ] Verify a fresh Android-to-desktop and desktop-to-Android pairing after a
  clean deploy; existing databases may contain capability records from the
  previous proof-direction implementation.
