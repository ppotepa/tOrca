# Torca architecture

This document defines the canonical ownership boundaries for Torca. It is the
starting point for the 0.3 refactor and supersedes informal ownership inferred
from file locations.

The objective is not to create more layers. The objective is to ensure that
one responsibility has one owner, one source of truth, and one recovery path.

## System overview

```text
Flutter presentation
    -> generated engine contract
    -> platform runtime bridge / FFI
    -> ClientEngine actor
    -> domain runtime
    -> storage / crypto / peer transport / rendezvous effects
    -> committed projection revision
    -> Flutter render
```

The application is split into four ownership areas:

1. **Frontend** — Flutter presentation and user interaction.
2. **Backend** — Rust engine and domain runtime.
3. **Persistence and security infrastructure** — SQLite storage and crypto.
4. **Platform hosts** — Android and Windows lifecycle adapters.

## Frontend ownership

Flutter owns presentation only.

Flutter may own:

- widgets and layouts;
- navigation and route presentation;
- dialogs, sheets, menus and toasts;
- localization and formatting;
- form validation that does not change domain semantics;
- draft text, search query and scroll position;
- which tab, modal or screen is open;
- short-lived button state such as idle, running, succeeded or failed;
- mapping stable backend error codes to localized text;
- sending explicit user intentions to the engine.

Flutter must not own:

- pairing state transitions;
- pairing recovery or convergence;
- message delivery retry;
- receipt retry;
- peer retry or Tor retry policy;
- durable operation state;
- idempotency decisions;
- creation of contacts or conversations after pairing;
- automatic verification of a newly paired contact;
- loops that wait for a contact, conversation, message or receipt to appear;
- repair of missing domain records;
- an alternative contact, conversation or pairing source of truth;
- interpretation of MLS, peer protocol or rendezvous stages.

A Flutter component may temporarily display that an engine command is in
progress. It must not decide that the durable workflow has completed. The
completion state must arrive from a backend projection.

## Backend ownership

The Rust backend consists of the client engine actor and the domain runtime.

The backend owns:

- identity and profile semantics;
- pairing and crossed-pairing convergence;
- contacts and relationship lifecycle;
- conversations and messages;
- message, delivery and read-receipt state;
- presence and typing semantics;
- endpoint capabilities and peer state;
- idempotency and command replay;
- durable retry and dead-letter decisions;
- long-running operation state;
- restart recovery;
- decisions to schedule network or platform effects;
- authoritative application projections;
- stable public error codes.

### ClientEngine actor

The actor is the single serialized application command boundary. It owns:

- engine lifecycle;
- command validation and command-id policy;
- serialization of mutating commands;
- idempotency lookup and result persistence;
- transaction boundaries;
- effect scheduling after durable state is committed;
- scheduler input and retry wake-ups;
- projection publication;
- public response and error envelopes.

The actor must not contain a second copy of domain rules that already belong to
the runtime. It coordinates runtime, storage, transport and platform effects.

### Domain runtime

The runtime owns domain decisions and workflow convergence. It must be split by
business feature rather than by UI screen or transport implementation.

Target feature areas:

```text
profile
pairing
contacts
relationships
conversations
messaging
receipts
presence
peer
```

`ClientRuntime` may remain a facade while features are extracted. The facade
must delegate; it must not retain parallel implementations in `runtime.rs`.

## Storage ownership

`torchat-storage` is the only owner of SQLite implementation and raw SQL.

Storage owns:

- SQLite connections and pragmas;
- transactions and savepoints;
- migrations;
- parameter binding;
- row decoding;
- point lookups and list queries;
- persistence of durable operations, retry state and projection revisions;
- storage-specific error context.

All SQL queries, commands and migrations live under:

```text
packages/torchat-storage/sql/
```

Runtime, engine, FFI, Flutter and platform hosts must not contain raw SQL.
Storage interfaces must not silently return success for required operations.
Optional capabilities must return an explicit unsupported or unavailable
result, never a false success.

## Crypto ownership

Crypto code owns cryptographic primitives and MLS state transformations. It
must not depend on Flutter, engine actors, SQLite implementations or platform
UI APIs.

Crypto code may return technical errors to the backend. User-facing wording is
created only by Flutter localization from a stable backend error code.

## Transport ownership

Peer and rendezvous transports own wire framing, connection management and
transport-specific validation. They do not own domain completion.

Examples:

- peer transport may report that a frame was persisted or rejected;
- rendezvous may report that an offer, rejection or Welcome was received;
- the runtime decides how that result advances a durable workflow.

Normal application messages use direct peer transport. The rendezvous relay is
not a message-forwarding fallback.

## Platform host ownership

Android and Windows hosts own operating-system integration:

- process and native runtime lifecycle;
- foreground service, tray and window lifecycle;
- Tor process lifecycle;
- onion-service configuration requested by the engine;
- secure storage and OS vault integration;
- notification delivery;
- permissions, autostart and background restrictions;
- forwarding typed platform facts to the engine.

A platform host must not implement pairing, message retry, relationship repair
or domain state transitions.

## State and projections

The backend publishes the authoritative domain state.

Global domain state is represented by `ApplicationSnapshot`. Large or
high-frequency collections, especially message history, use separate revisioned
projections such as `ConversationProjection`.

Every authoritative projection must identify:

- the durable store;
- the engine session when needed;
- a monotonic revision.

Flutter may reject an older projection from the same store. Flutter must not
manufacture a newer domain revision by locally patching a durable collection.

Presentation-only state remains outside the backend snapshot, for example:

- selected tab;
- open modal;
- scroll position;
- draft text;
- search text.

## Durable workflow rule

Every operation that spans a transaction, network effect or process restart
must follow this shape:

```text
validate intention
-> persist intention/state
-> commit
-> perform effect
-> persist effect outcome
-> converge domain state
-> publish revision
```

Network I/O must not be performed while holding a long SQLite transaction.
A crash between any two durable steps must be recoverable from persisted state.

Examples include:

- pairing;
- relationship removal;
- message delivery;
- receipt delivery;
- endpoint rotation.

## Command and event contract

Rust, Dart and Kotlin share one generated wire contract. The contract is the
single source for:

- public methods;
- command wire names;
- request and response DTOs;
- events and platform facts;
- idempotency requirements;
- command execution category;
- stable error envelopes.

Generators may create constants, DTOs, metadata, completeness checks and
documentation. Generators must not contain domain workflow logic.

## Error boundary

Backend errors exposed to Flutter contain stable semantics:

```text
code
category
retryable
operation_id (optional)
entity_id (optional)
```

Technical source chains remain in sanitized logs. Raw rusqlite, crypto, HTTP or
Tor messages must not be rendered directly to users.

## Refactor rules

For every move or extraction:

1. Identify the current owner and all call sites.
2. State the intended owner after the change.
3. Preserve one active implementation.
4. Add or identify the behavior test that proves equivalence.
5. Remove the old path in the same batch once consumers are migrated.
6. Do not add `legacy`, `v2`, `new`, `old` or compatibility implementations.
7. Do not create a manager, controller, repository or event bus unless it
   removes an existing responsibility from another owner.
8. Do not change wire protocol, database schema or ABI without explicit
   versioning and migration tests.

## Definition of architectural success

The 0.3 architecture is considered established when:

- Flutter has no domain retry or pairing recovery;
- pairing has one durable state machine in Rust;
- one application controller submits intentions and observes projections;
- `main.dart` is a composition root;
- `ApplicationSnapshot` is the domain source of truth;
- runtime code is organized by business feature;
- required storage operations have explicit implementations;
- point lookups replace full-list scans;
- one command pipeline coordinates persistence and effects;
- one contract generates Rust/Dart/Kotlin wire definitions;
- platform hosts contain no domain workflow;
- no god object remains the owner of unrelated frontend and backend concerns.
