# Torca responsibility matrix

This matrix assigns every major responsibility to exactly one owner. Other
layers may request, transport or present a result, but must not implement a
second source of truth.

| Responsibility | Owner | Allowed collaborators | Forbidden duplicate |
| --- | --- | --- | --- |
| Identity semantics | Rust runtime | crypto, storage | Flutter or platform-generated identity state |
| Profile semantics | Rust runtime | storage | profile reconciliation in widgets |
| Pairing state transitions | Rust pairing feature | engine, storage, rendezvous, peer | Flutter pairing recovery state machine |
| Pairing retry and expiry | Client engine + Rust pairing feature | scheduler, clock, storage | `Timer.periodic` or `Future.delayed` retry in Flutter |
| Pairing dialog presentation | Flutter pairing UI | application snapshot | protocol interpretation in dialog code |
| Crossed pairing convergence | Rust pairing feature | storage, peer | UI-side contact matching |
| Contact creation | Rust runtime | storage | contact insertion or repair in Flutter |
| Relationship lifecycle | Rust relationships feature | storage, messaging | relationship transition in UI or transport |
| Conversation creation | Rust conversations feature | storage | automatic UI-created conversation after pairing |
| Message persistence | Storage | runtime transaction | in-memory-only authoritative message state |
| Message send workflow | Rust messaging feature + engine effects | storage, peer | automatic transport retry in Flutter |
| Delivery/read receipts | Rust receipts feature | storage, peer | UI-managed receipt queues |
| Presence and typing semantics | Rust runtime | engine, peer | lifecycle widget directly deciding durable state |
| Peer endpoint capability | Rust runtime | storage, peer | platform or Flutter capability lifecycle |
| Peer connection state | Client engine | peer transport, platform facts | independently derived UI connection state |
| Tor process lifecycle | Platform host | engine platform actions | runtime starting OS processes directly |
| Onion-service decision | Client engine | platform host, Tor | platform host deciding domain timing |
| Onion-service execution | Platform host | Tor runtime | Flutter implementation |
| Rendezvous slot/bridge transport | Rendezvous relay/client | relay protocol | relay domain completion or message fallback |
| Application message transport | Peer transport | engine/runtime | relay forwarding fallback |
| Command serialization | ClientEngine actor | contract, runtime | multiple mutating command queues |
| Idempotency policy | Client engine contract/pipeline | storage | per-widget or per-handler ad hoc policy |
| Durable operation recovery | Rust runtime + engine scheduler | storage, clock | recovery controller in Flutter |
| Application projection revision | Backend storage/runtime | engine publisher | UI-generated domain revision |
| Application snapshot storage | Flutter projection store | generated DTO | controller-maintained duplicate collections |
| Active message page | Flutter projection store | backend conversation projection | inclusion of all history in global snapshot |
| Navigation | Flutter | navigation intent port | engine route selection |
| Dialog ordering | Flutter dialog coordinator | snapshot | domain decision based on open dialog |
| Form/draft state | Flutter | none | backend persistence unless explicitly a feature |
| UI busy state | Flutter operation registry | command result | representation of durable workflow completion |
| Stable public error code | Client engine | runtime/storage mapping | classification by matching error text in Flutter |
| User-facing error text | Flutter localization | stable error code | localized strings in Rust |
| Technical diagnostics | Backend/platform logging | redaction helpers | plaintext messages, secrets or raw payloads |
| SQLite and SQL | torchat-storage | runtime storage traits | raw SQL in runtime, engine, FFI, Flutter or host |
| Database migration | torchat-storage | release compatibility tests | schema mutation in application layers |
| MLS and crypto transformations | torchat-crypto/runtime | storage anchors | crypto rules in engine or UI |
| Rust/Dart/Kotlin wire definitions | Contract manifest + generator | handler completeness tests | manually synchronized parallel lists |
| Native ABI | torchat-client-engine-ffi | Android/Windows hosts | platform-specific domain APIs |
| Android service lifecycle | Android host | runtime bridge | domain state machine in Kotlin |
| Windows process/tray lifecycle | Windows host | runtime bridge | domain state machine in Dart/native host |
| Notifications | Platform adapter | Flutter preferences, engine event | platform code changing domain state |
| Release version | `release/version.json` | build scripts | independent hardcoded app versions |

## Ownership test for new code

Before adding a feature or abstraction, answer:

1. Which row owns the responsibility?
2. Does an implementation already exist under that owner?
3. Does the change remove or create a source of truth?
4. Can the operation survive process restart?
5. Is the command idempotent where required?
6. Is network I/O scheduled only after durable state is committed?
7. Does Flutter only render and submit an intention?
8. Does SQL remain under `torchat-storage/sql`?
9. Does the wire model come from the contract manifest?
10. Does the public error use a stable code?

A proposed component that cannot be assigned to one row must not be introduced
until its ownership is resolved.
