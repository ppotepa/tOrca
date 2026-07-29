# TorChat Client Engine Contract v3

`common/client-engine-contract.json` is the machine-readable source of truth for
the generated engine contract. It currently uses protocol version `1`, and the
generator in `tools/torchat-contract-gen` produces the host artifacts from that
manifest. This document explains that contract and the engine API described in
`REFACTO1.MD`.

This contract replaces the old adapter-oriented runtime surface. Android,
desktop, Flutter, and future hosts must align request names, response shapes,
connection states, and emitted events with this document.

## Scope

The shared Rust ClientEngine owns:

- lifecycle-safe command dispatch;
- runtime transaction boundaries;
- canonical runtime event publication;
- connection state classification;
- platform fact ingestion;
- notification requests for platform hosts;
- stable JSON/FFI envelopes consumed by Android and desktop hosts.

The shared Rust ClientEngine does not expose:

- direct database handles;
- runtime storage implementations;
- MLS conversation objects;
- relay writer internals;
- retry scheduler internals;
- mutable runtime session internals.

Generated host artifacts are produced by `tools/torchat-contract-gen` and
written to:

- `mobile/android/app/src/main/kotlin/org/torchat/generated/EngineContract.kt`
- `mobile/lib/core/runtime/generated/runtime_contract.g.dart`
- `mobile/lib/core/models/generated/runtime_models.g.dart`

## EngineConfig

The platform host constructs `EngineConfig` once and passes it to the engine at
startup.

Fields:

- `databasePath: string`
- `databaseKey: bytes`
- `identityPrivateKey: bytes`
- `relayOnionUrl: string`
- `initialSocks5Url?: string`
- `logDirectory?: string`
- `platform: "android" | "desktop" | "ios" | "macos" | "linux" | "windows"`

The host provides paths, secrets, and the initial SOCKS endpoint. The engine
interprets them identically across platforms.

## EngineCommand

Public commands:

- `bootstrap`
- `connect`
- `getIdentity`
- `getProfile`
- `pairingInbox`
- `pairingOutbox`
- `listContacts`
- `listConversations`
- `listMessages`
- `setNickname`
- `refreshPairingCode`
- `submitPairingCode`
- `acceptPairing`
- `rejectPairing`
- `cancelPairing`
- `archivePairing`
- `verifyContact`
- `startConversation`
- `openConversation`
- `closeConversation`
- `sendMessage`
- `platformFact`
- `shutdown`

Query command rules:

- `listContacts` returns contacts ordered by the engine-owned storage view.
- `listConversations` returns conversations ordered by `lastMessageAt`
  descending.
- `listMessages` returns messages for one `conversationId` ordered by
  `createdAt` ascending.
- `getIdentity`, `getProfile`, `pairingInbox`, and `pairingOutbox` return
  canonical runtime DTOs through the same `response` envelope.
- Empty lists are successful responses, never `null` and never command errors.

The public contract intentionally excludes adapter-only commands such as:

- `bootstrapRuntime`
- `reportTorStatus`
- `prepareAcceptPairing`
- `commitAcceptPairing`
- `prepareRejectPairing`
- `commitRejectPairing`
- `prepareCancelPairing`
- `confirmPairingCancelled`
- `preparePendingSendEffects`
- `preparePendingReceiptEffects`
- `expediteRetryAfterReady`
- `applyMessageTransportOutcome`
- `welcomeAccepted`
- `bootstrapContact`

These remain internal engine/runtime operations and must not be reintroduced
into Flutter, Android, desktop, or generated wire contracts.

## Command Envelope

The platform submits one logical command per envelope.

JSON shape:

```json
{
  "requestId": "string",
  "command": {
    "type": "send_message",
    "conversation_id": "peer-1",
    "body": "hello"
  }
}
```

`requestId` is required for correlating asynchronous responses.

Wire naming is intentionally split into three generated namespaces:

- public Flutter/MethodChannel method names use camelCase, for example
  `sendMessage`;
- `EngineCommand` tags and command fields use the exact Rust serde snake_case
  names, for example `send_message` and `conversation_id`;
- response DTOs and engine-event fields use camelCase, for example
  `conversationId`, `requestId`, and `retryAttempt`.

Hosts must use the generated constants and parsers rather than translating
these names manually.


## Response Envelope

Every accepted command produces exactly one `response` event with the same
`requestId`. Successful responses always contain an explicit payload envelope:

```json
{
  "type": "response",
  "requestId": "string",
  "result": {
    "status": "ok",
    "payload": { "type": "empty" }
  }
}
```

JSON results use `{ "type": "json", "value": ... }`. Missing payloads,
unknown event types, unknown statuses, and unknown payload types are contract
errors in generated Kotlin and Dart parsers.

## PlatformFact

Platform hosts report facts, not derived business state.

Supported facts:

- `tor_status`
- `tor_endpoint_available`
- `tor_endpoint_lost`
- `app_visibility_changed`
- `network_changed`

The engine converts these facts into connection state changes, retry behavior,
and user-facing runtime events.

## EngineEvent

The engine emits one of:

- `response`
- `runtime`
- `connection`
- `notification_requested`
- `log`
- `fatal`

`runtime` wraps canonical `RuntimeEvent` values from
`common/torchat-client-runtime`.

`connection` exposes engine-owned connection state, not platform-computed
status.

`notification_requested` contains a fully prepared notification request for the
platform host to display.

## Transactions

One public command maps to one engine transaction boundary.

Rules:

- durable storage changes must commit before business events are published;
- runtime staged events publish only after commit;
- on rollback, runtime session and in-memory engine state must be restored;
- platforms must not emit synthetic business events to compensate for
  uncommitted work.

## Shutdown

Shutdown must be idempotent.

Rules:

- no new commands are accepted after shutdown begins;
- polling may drain already queued terminal events;
- no callbacks or events may be emitted after the handle is freed on the FFI
  boundary.

## FFI Surface

The stable engine ABI is:

- `torchat_client_engine_new`
- `torchat_client_engine_start`
- `torchat_client_engine_submit_json`
- `torchat_client_engine_poll_json`
- `torchat_client_engine_platform_fact_json`
- `torchat_client_engine_shutdown`
- `torchat_client_engine_free`
- `torchat_client_engine_last_error`
- `torchat_client_engine_free_string`

The ABI exchanges UTF-8 JSON envelopes and must not reintroduce
runtime-state import/export side channels or any adapter-only session
snapshots.
