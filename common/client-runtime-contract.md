# Flutter client runtime contract v2

The Flutter application is the only UI. Android backs this contract with the
foreground service MethodChannel/EventChannel. Desktop backs the same contract
with the Rust sidecar (`torchat-desktop --stdio-runtime`) over JSON Lines.

Every runtime request is a command with an optional payload. Desktop requests
are JSON objects with `id`, `method` and optional `params`; responses contain
the same `id`, `ok` and either `result` or `error`. Android exposes the same
method names through `org.torchat/mobile`.

Canonical methods:

- `connect`
- `identity`
- `profile`
- `setNickname`
- `refreshPairingCode`
- `prepareSubmitPairingCode`
- `submitPairingCode`
- `pairingInbox`
- `mergePairingInbox`
- `pairingOutbox`
- `mergePairingOutbox`
- `acceptPairing`
- `rejectPairing`
- `archivePairing`
- `cancelPairing`
- `verifyContact`
- `contacts`
- `conversations`
- `messages`
- `openConversation`
- `closeConversation`
- `startConversation`
- `sendMessage`
- `receiveMessage`
- `preparePendingSendEffects`
- `applyMessageTransportOutcome`

Adapter-only runtime methods:

- `prepareAcceptPairing`
- `commitAcceptPairing`
- `prepareRejectPairing`
- `commitRejectPairing`
- `prepareCancelPairing`
- `confirmPairingCancelled`
- `welcomeAccepted`
- `applyPairingPeerOutcome`

These methods are not UI surface. Android and desktop may use them inside a
composite platform operation to perform Tor relay, MLS, and local storage work
around canonical runtime effects.

`identity` returns the local installation identity only:
`installationId`, `publicKey`, `fingerprint`.
`profile` returns the user profile and includes `nickname` in addition to the
identity fields.

Canonical event types:

- `runtime_ready`
- `tor_status`
- `profile_ready`
- `invite_received`
- `invite_state_changed`
- `message_received`
- `message_state_changed`
- `conversation_read_changed`
- `changed`
- `runtime_error`
- `runtime_log`

`tor_status` events use `phase`, `label`, `detail`, `progress`, `latencyMs`
and `retryAttempt`. `retryAttempt` is the canonical retry counter; legacy
payloads may still surface `attempt` in older adapters, but new adapters and
fixtures must emit `retryAttempt`.

Canonical DTO examples live in `common/client-runtime-fixtures.json`. Runtime
adapters and Flutter parsers must stay compatible with those fixtures.

Canonical invite states use `SCREAMING_SNAKE_CASE`: `PENDING`, `ACCEPTED`,
`REJECTED`, `COMPLETED`, `EXPIRED`, `ARCHIVED`, `CANCELLED`. Both
`pairingInbox` and `pairingOutbox` items must expose `state`; terminal sent
invites remain visible as local outbox records until the user-visible flow
archives or clears local client state.

Canonical message states use `SCREAMING_SNAKE_CASE`: `QUEUED`, `SENDING`,
`SENT`, `DELIVERED`, `FAILED`. Runtimes may read legacy local `PENDING`
records as queued, but new events and DTOs must emit `QUEUED`.

Message sending is canonical in the runtime:
- `sendMessage` creates the outgoing record and returns `MessageSendEffect`.
- `preparePendingSendEffects` returns effects for retry candidates from runtime storage.
- `applyMessageTransportOutcome` maps `MessageTransportOutcome` back to canonical `MessageState`.

Canonical conversation states use `SCREAMING_SNAKE_CASE`: `PENDING`,
`VERIFYING`, `ACTIVE`, `OFFLINE`, `FAILED`. Runtimes may read legacy local
`NEW` records as pending, but new events and DTOs must emit `PENDING`.

The server never receives message bodies or MLS state. Identity, contacts,
conversation state, unread counters and the encrypted outbound queue stay in
the client-local store. Runtime adapters must not add LAN/clearnet fallbacks:
relay traffic uses the configured exact v3 onion through Tor.

Runtime adapters must bound foreground relay commands. Cold onion startup may
take minutes, but individual HTTP/WebSocket relay operations must either
complete, enter retry/reconnecting state, or surface a concrete error. They
must not leave Flutter waiting indefinitely for pairing-code, pairing-request
or WebSocket handshake results.

The relay may forward a ciphertext frame only to a currently connected
recipient WebSocket and may emit delivery/offline receipts. It must not create,
insert or update durable `message`, `envelope`, `payload`, `ciphertext`, `mls`,
`welcome` or `application` records. The `torchat test` command enforces this
with `scripts/internal/check-server-relay-ephemeral.ps1`.
