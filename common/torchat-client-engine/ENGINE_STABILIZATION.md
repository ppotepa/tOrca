# Engine stabilization architecture

The engine keeps the existing `ClientEngine` and `ClientEngineActor` wire contract while the stabilization pipeline is adopted incrementally.

## Canonical pipeline

```text
EngineCommandEnvelope
  -> EngineStabilizationPipeline::admit
  -> CommandRouter
  -> BackpressurePolicy
  -> CommandOutcome / EngineEffect
  -> DeliveryJob + DeliveryScheduler
  -> TransportRouter
  -> Relay or peer worker
  -> DeliveryOutcome
  -> domain state machine
  -> DomainEvent
  -> ApplicationSnapshotProjector
```

Inbound communication uses one transport-neutral path:

```text
relay or peer envelope
  -> InboundValidator
  -> InboundDeduplicator
  -> durable domain commit
  -> acknowledgement plan
```

## Safety rules

- Durable commands are persisted instead of dropped when queues are under pressure.
- Typing and presence are conflated and never displace durable work.
- Relay, peer, delivery and timer workers are restartable; state/storage failure is fatal.
- Reconnect and onion rotation use monotonically increasing generations.
- Snapshot patches require matching database identity and base generation.
- Structured diagnostics contain identifiers and reason codes, not message bodies or private key material.
- Legacy command envelopes remain supported; metadata is added internally through `ObservedCommandEnvelope`.

## Compatibility state

The original actor remains the production compatibility shell until local qualification completes. New modules are public and testable, allowing command families to be migrated one at a time without changing Android, desktop or FFI contracts.

Do not remove legacy paths until the corresponding new handler has been connected and the full qualification matrix succeeds.

## Required local validation

From the repository root:

```powershell
cargo fmt --all -- --check
cargo check -p torchat-client-runtime
cargo test -p torchat-client-runtime
cargo check -p torchat-client-engine
cargo test -p torchat-client-engine
cargo clippy -p torchat-client-runtime --all-targets -- -D warnings
cargo clippy -p torchat-client-engine --all-targets -- -D warnings
cargo build --workspace --release
```

Flutter and Android:

```powershell
cd mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
flutter build windows --debug
cd android
.\gradlew.bat :app:assembleDebug
```

Linux validation must be run on Linux:

```bash
cd mobile
flutter analyze
flutter test
flutter build linux --debug
```

## Manual qualification matrix

- P2P online, relay fallback, relay-only and peer-only delivery.
- Network loss during send and restart in queued/sending/forwarded states.
- Duplicate relay and peer envelopes.
- Pairing completion, rejection, cancellation, expiration and restart at each phase.
- Wi-Fi/LTE transitions, Android Home, Doze, battery saver and activity recreation.
- Relay, peer, delivery, projection and notification worker failures.
- Graceful shutdown while delivery work is pending.

A batch is complete only after its local tests pass. Connector commits alone are not evidence that native, Rust or Flutter builds succeeded.
