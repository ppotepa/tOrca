# Torca dependency rules

This document defines enforceable dependency direction. The ownership model is
described in `architecture.md` and `responsibility-matrix.md`.

Structural refactors must preserve runtime behavior, pairing semantics,
protocol compatibility, database compatibility and the public FFI contract.

## Canonical dependency direction

```text
Flutter feature/presentation
    -> generated wire contract and application ports
    -> platform runtime bridge / FFI
    -> torchat-client-engine
    -> torchat-runtime
    -> domain protocol / crypto abstractions

torchat-client-engine
    -> torchat-storage
    -> torchat-peer
    -> torchat-rendezvous-client

Android/Windows host
    -> torchat-client-engine-ffi or runtime bridge
    -> operating-system APIs and Tor process

services/torchat-relay
    -> torchat-relay-protocol
```

Dependencies may point toward lower-level capabilities. Lower-level code must
not import or call presentation or application-composition layers.

## Frontend rules

Flutter feature code may depend on:

- generated DTOs and wire constants;
- application snapshot and projection models;
- application controller intentions;
- presentation components;
- explicit platform port interfaces exposed through providers.

Flutter feature code must not depend on:

- Android or desktop implementation directories;
- raw FFI implementation details;
- SQLite, SQLCipher or raw SQL;
- Tor process or onion-service implementation;
- peer/rendezvous protocol internals;
- engine actor internals;
- mutable global `PlatformServices.current` outside composition roots.

Flutter must not contain domain retry or recovery. The following patterns are
forbidden when used to converge domain state:

- `Timer.periodic`;
- retry loops using `Future.delayed`;
- repeated `refreshData` waiting for a contact, conversation or message;
- local sets that decide whether a pairing has been resolved;
- automatic domain mutation triggered by observing a local collection change.

Timers remain allowed for presentation behavior such as debounce, animation or
short-lived visual feedback when they do not decide domain completion.

## Backend rules

### Client engine

The engine may depend on runtime, storage, transport, protocol and platform-fact
contracts. It must not depend on Flutter or platform UI code.

There is one mutating command pipeline. A second actor loop, compatibility
router or alternate command path is forbidden.

Network effects must be scheduled after the durable intent has been committed.
The engine must not hold a long SQLite transaction while awaiting network I/O.

### Domain runtime

Runtime/domain code may depend on domain contracts, storage capability traits,
crypto abstractions and an injected clock. It must not depend on:

- ClientEngine actor implementation;
- FFI;
- Flutter/Dart/Kotlin;
- Android or Windows APIs;
- SQLite implementation details;
- filesystem or network implementation when a port exists.

Domain workflow decisions must use `RuntimeClock`. Direct wall-clock access in
feature modules is forbidden after the clock migration.

### Storage

Only `packages/torchat-storage` may own raw SQL or `rusqlite` implementation.
All SQL queries, commands and migrations live under:

```text
packages/torchat-storage/sql/
```

Runtime storage traits expose semantic operations. Required operations must not
have a default `Ok(())`, empty collection or `None` implementation. Point
lookups must be used instead of list-then-find when the point operation exists.

Applied migrations are never deleted or rewritten.

### Crypto and protocol

Crypto and protocol crates must not depend on engine, storage implementation,
FFI, Flutter or platform hosts. They may define validated wire/domain types and
cryptographic transformations.

### Relay

Relay code must not depend on:

- client storage;
- client runtime;
- client engine;
- peer application-message transport;
- application message models.

The relay may depend on relay protocol types. It remains an ephemeral
rendezvous service and never becomes an application-message fallback.

## Platform host rules

Platform hosts may depend on operating-system APIs, Tor runtime, generated
contract code and the engine boundary.

They may execute platform actions and publish platform facts. They must not
implement pairing, message retry, relationship repair, idempotency or durable
workflow transitions.

## Contract rules

Rust, Dart and Kotlin wire definitions originate from one manifest. Generated
files are not edited manually.

The contract generator may produce:

- constants and enums;
- request/response DTOs;
- metadata;
- documentation;
- completeness checks.

It must not produce domain workflow implementation.

A durable mutation without command-id metadata is forbidden.

## Error and presentation text rules

Backend code emits stable error codes and sanitized diagnostic context. It must
not create localized user-facing labels. Flutter maps error codes and semantic
preview/status values to localized text.

Raw dependency errors from SQLite, crypto, HTTP, WebSocket or Tor are not shown
directly to users.

## Source-of-truth rules

- Rust is authoritative for domain and workflow state.
- Backend projections are authoritative for durable UI data.
- Flutter owns presentation-only state.
- Storage is authoritative for committed persistence.
- The contract manifest is authoritative for wire names.
- `release/version.json` is authoritative for product version.

A new cache or projection must define its authority, revision rule and
invalidation owner. A cache must never silently become another source of truth.

## Refactor rule

Before changing a boundary:

1. identify the current owner;
2. list all readers and writers;
3. identify persisted state and network effects;
4. name the behavior test that protects the change;
5. migrate consumers in small steps;
6. remove the old path in the same batch after migration;
7. search for the old symbol and forbidden imports;
8. record tests that were not run.

Do not add `legacy`, `v2`, `new`, `old`, compatibility wrappers or parallel
implementations. A temporary adapter is allowed only when its removal is part
of the same documented migration and it does not execute independent logic.
