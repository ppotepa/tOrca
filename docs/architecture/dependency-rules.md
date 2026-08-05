# TorChat dependency rules

This document is the repository boundary contract. Structural refactors must
preserve runtime behavior, pairing semantics, protocol compatibility, and the
public FFI contract.

## Rust layers

The intended dependency direction is:

```text
desktop host / platform applications
    -> torchat-client-engine
    -> torchat-runtime
    -> torchat-core
```

The engine may own client storage, peer transport, and the rendezvous client
until those responsibilities are extracted into independently tested crates.
The relay may depend on shared rendezvous protocol types, but never on client
storage, client runtime, client engine, peer transport, or application message
types.

When the target crates exist, the dependency direction becomes:

```text
apps/*/native -> client-engine -> runtime/domain/protocol/crypto
client-engine -> storage/peer/rendezvous-client
services/torchat-relay -> relay-protocol [-> crypto only when required]
```

## Forbidden dependencies

- Relay code must not depend on `rusqlite`, SQL repositories, client engine,
  client runtime, or peer transport.
- Protocol code must not depend on SQLite, actor runtime, or UI.
- Domain code must not depend on filesystem, WebSocket, Tor, or Android/Windows
  APIs.
- Normal application messages must use direct peer transport, never relay
  forwarding or relay fallback.
- The public FFI surface remains the only native engine boundary.

## Flutter layers

`apps/mobile/flutter` is the application composition layer. Shared
presentation primitives and theme belong in `packages/torchat-flutter-ui`.
That package may depend on Flutter presentation libraries, but not on native
bridges, SQLCipher, Tor, or client-runtime ownership. Shared features may
depend on shared presentation/runtime contracts, but not on
native bridges, SQLCipher, Tor, or platform APIs. Platform adapters own
Android- and desktop-specific lifecycle, notifications, permissions, and host
integration. Only the application composition root connects a platform adapter
to the runtime bridge.

## SQL boundary

Until storage extraction is complete, new SQL lives under
`packages/torchat-storage/sql/` and is registered through
`packages/torchat-storage/src/storage/sqlite/sql_catalog.rs`. Applied
migrations are never deleted.

## Refactor rule

Before moving a file, identify its owner, classify it as shared/client/relay/
platform-only, list the allowed post-move dependencies, and name the test that
proves behavior is unchanged. Use one direct path after the move; do not add
`v2`, `legacy`, or parallel wrapper paths.
