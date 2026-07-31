# tOrca

**tOrca** is an experimental, cross-platform private messenger built with Flutter and Rust. The application is currently presented as **TorChat** and focuses on reliable one-to-one communication over Tor v3 onion services.

> [!WARNING]
> This project is under active development. Its protocol, storage format, user experience and security properties may change. It has not completed an independent security audit and should not yet be treated as production-ready software.

## Project goals

tOrca explores a local-first messenger in which:

- users create an installation identity without an email address, phone number or password;
- contacts are established through an expiring pairing code or QR code and explicit acceptance;
- message content, conversation history, private keys and MLS state remain on client devices;
- network traffic is routed through Tor;
- an untrusted relay coordinates pairing and transports opaque encrypted envelopes;
- Android and desktop share the same Flutter interface and as much Rust client logic as possible.

The current `0.1` release focus is Windows and Android. See [RELEASE_0_1.md](RELEASE_0_1.md) for the frozen feature scope and acceptance criteria.

## How it works

1. Each installation creates a local identity and connects through its local Tor runtime.
2. Users exchange a short-lived pairing code or QR code.
3. Explicit acceptance creates a trusted contact and conversation.
4. The shared Rust client prepares local message state and cryptographic envelopes.
5. The current transport sends opaque envelopes through a configured Tor v3 onion relay.
6. The recipient processes and stores the message locally.

The relay is not part of the cryptographic trust boundary. It may authenticate sessions and coordinate delivery, but it must not receive client private keys or plaintext messages.

## Architecture

![tOrca architecture](assets/architecture.svg)

The codebase separates presentation, domain rules, cryptography, transport and platform lifecycle:

- **`mobile/lib`** — shared Flutter UI, application controller and platform-neutral `ClientRuntime` contract.
- **`common/torchat-client-runtime`** — canonical pairing, contact, conversation and message lifecycle rules.
- **`common/torchat-client-engine`** — shared client engine for persistence, queues, network state and transport integration.
- **`common/torchat-client-engine-ffi`** — C ABI boundary for native integrations.
- **`common/torchat-core`** — identity, protocol validation, wire types and MLS-based cryptographic components.
- **`mobile/android`** — Android service lifecycle, native channels, local Tor integration and encrypted persistence.
- **`desktop`** — desktop process lifecycle, local Tor integration and the Flutter runtime bridge.
- **`server/torchat-server`** — untrusted HTTP/WebSocket relay and pairing control plane.
- **`infra`** — local Tor, database and container infrastructure.

Flutter is intentionally a presentation layer. Pairing transitions, contact state, message delivery state and deduplication belong to the shared Rust runtime rather than separate Android, desktop or Dart implementations.

## Transport model

The currently implemented transport uses a configured onion relay:

```text
Client A -> local Tor -> Tor v3 onion relay -> local Tor -> Client B
```

The client architecture is transport-independent. Direct device-to-device onion delivery is a possible future strategy, but it is not a current release guarantee.

## Technology

- Flutter and Dart
- Rust
- OpenMLS and Ed25519-based identity components
- Tor v3 onion services
- WebSocket and HTTP transport
- SQLite / SQLCipher-compatible local persistence
- PostgreSQL for relay control-plane state

## Current limitations

The project is still stabilizing startup, reconnect behavior, background lifecycle, pairing recovery, durable delivery and cross-platform release quality. Features such as calls, groups, multi-device synchronization, public discovery and cloud backup are outside the `0.1` scope.

## Development

The repository uses a Rust workspace for shared components and a Flutter application for Android and desktop surfaces. Development and deployment commands are centralized under:

```text
scripts/torchat.ps1
```

Environment-specific onion endpoints and secrets must not be committed.

## License

The Rust workspace is licensed under **AGPL-3.0-or-later**.
