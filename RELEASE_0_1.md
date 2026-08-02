# TorChat 0.1 — frozen release scope

Status values: `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `IMPLEMENTED`, `VERIFIED_WINDOWS`, `VERIFIED_ANDROID`, `DONE`.

## Product definition

TorChat 0.1 is a reliable private 1:1 messenger for Windows and Android. The scope is frozen. Bug fixes and UX work inside this document are allowed; new product features go to 0.2.

## Explicitly excluded

- audio and video calls
- voice messages and arbitrary files
- protocol-level groups
- multi-device accounts and history synchronization
- edit or remote-delete sent messages
- reactions, disappearing messages, public search and cloud backup

## Trust model

Entering a pairing code and explicitly accepting the request establishes trust. Pairing completion must produce a verified contact and active conversation on both sides. No additional `Verify contact` action is required; it produces a verified contact and an active conversation on both sides.

## Epic 1 — startup and lifecycle

| Item | Status |
|---|---|
| Deterministic sequential warmup | IMPLEMENTED |
| Restore local shell and snapshot after restart | IMPLEMENTED |
| Reliable reconnect without fatal network state | IMPLEMENTED |
| Persist desktop size and position | IMPLEMENTED |
| Close desktop window to background | IMPLEMENTED |
| Desktop tray with show, settings and exit | IMPLEMENTED |
| Single desktop application instance | IMPLEMENTED |
| Desktop autostart setting | IMPLEMENTED |
| Desktop lifecycle verified on Windows | NOT_STARTED |

Returning users enter the local shell when the local runtime is ready, without waiting for network recovery. Reconnect has one generation owner, bounded exponential backoff, stale-event rejection and non-fatal network/Tor waiting states. Repeated-disconnect tests verify that retry delay remains capped and the process never enters a fatal state. Desktop lifecycle and autostart are implemented, but Windows verification remains outstanding.

## Epic 2 — pairing

| Item | Status |
|---|---|
| Generate, enter and scan pairing code | IMPLEMENTED |
| Accept, reject and cancel pairing | IMPLEMENTED |
| Persist control-plane state across reconnect | IMPLEMENTED |
| Automatically trust newly paired contacts | IMPLEMENTED |
| Automatically activate conversation | IMPLEMENTED |
| Automatically open new conversation | IMPLEMENTED |
| Prevent duplicate acceptance and contacts | IMPLEMENTED |
| Deterministic local connection system event | IMPLEMENTED |
| Twenty symmetric pairing runs per direction | NOT_STARTED |

Accepted pairing responses, relay acknowledgements, retry counters, deadlines and errors are persisted in SQLCipher. Restart coverage confirms that each pairing ID owns one retry record, duplicate acknowledgement updates rather than duplicates it, and confirmed delivery atomically removes further retry work. The runtime merges inbox items by pairing ID, rejects a second active outbox request and permits idempotent re-acceptance only when retained invite artifacts match. The active conversation boundary and local notices provide deterministic connection state without injecting a second network message. Twenty-run device verification remains outstanding.

## Epic 3 — contact lifecycle

| Item | Status |
|---|---|
| Local alias, mute and block | IMPLEMENTED |
| Contact details and transport controls | IMPLEMENTED |
| Contact context menu | IMPLEMENTED |
| Versioned ContactRemoved wire payload | IMPLEMENTED |
| Transactional local relationship removal | IMPLEMENTED |
| Remote relationship removal | IMPLEMENTED |
| Block sending after removal | IMPLEMENTED |
| Preserve/delete history choice | IMPLEMENTED |
| Fresh re-pair and MLS state after removal | IMPLEMENTED |

The contact menu supports opening a conversation, details, mute/unmute, fingerprint copy and confirmed relationship removal. Local removal atomically writes a tombstone, disables the contact, stops ordinary queued messages, removes MLS and peer endpoint state and applies the selected local-history policy while preserving only the durable removal delivery.

Incoming removal messages are recognized at the encrypted SQLCipher persistence boundary before a new application snapshot can be exposed. Relationship boundaries advance when a relationship is created or reactivated, so delayed tombstones from an older relationship are consumed without mutating a fresh pairing. Integration coverage verifies atomic remote removal, MLS suppression, history policy, fresh re-pair and stale replay isolation. Platform verification remains outstanding.

## Epic 4 — conversations

| Item | Status |
|---|---|
| Optimistic conversation row | IMPLEMENTED |
| Local title | IMPLEMENTED |
| Pin conversation | IMPLEMENTED |
| Mute conversation | IMPLEMENTED |
| Archive conversation locally | IMPLEMENTED |
| Desktop/mobile context menu | IMPLEMENTED |
| Clear local history | IMPLEMENTED |
| Local system events | IMPLEMENTED |

The timeline renders deterministic local states for a new secure conversation and relationship termination. Local history clearing uses the runtime delete operation for every persisted message in the selected conversation, clears repository paging state and keeps the contact relationship intact.

## Epic 5 — text messaging

| Item | Status |
|---|---|
| Durable outgoing queue | IMPLEMENTED |
| Offline and reconnect delivery | IMPLEMENTED |
| Idempotent inbound processing | IMPLEMENTED |
| Queued/sending/sent/delivered/read/failed states | IMPLEMENTED |
| Reply, copy, retry and local delete | IMPLEMENTED |
| Local search in current conversation | IMPLEMENTED |
| Persist sent/delivered/read timestamps | IMPLEMENTED |

The encrypted client store owns one outbound-delivery row per public message ID. Restart recovery requeues `IN_FLIGHT` work without resetting the attempt count or creating duplicates. Inbound peer envelopes are keyed by authenticated sender and message ID; identical replay is classified as duplicate after restart, while the same ID with a different ciphertext hash is rejected. Real cross-platform offline/reconnect verification remains outstanding.

Message state transitions are recorded in `message_state_timestamps` inside SQLCipher. Idempotent triggers preserve the first `sent_at`, `delivered_at` and `read_at` values, and integration coverage checks monotonic transitions, restart persistence and cascading deletion.

## Epic 6 — timeline and scrolling

| Item | Status |
|---|---|
| Open at newest message | IMPLEMENTED |
| Auto-scroll near bottom | IMPLEMENTED |
| Preserve position while reading older messages | IMPLEMENTED |
| New-message counter and jump to bottom | IMPLEMENTED |
| Own sent message scrolls to bottom | IMPLEMENTED |
| Status updates do not force scroll | IMPLEMENTED |
| SQLite pagination and prepend preservation | IMPLEMENTED |
| Restore per-conversation scroll position | IMPLEMENTED |

The runtime reads the newest 50 SQLite rows by default and exposes older pages through a stable `(created_at, id)` cursor with bounded `LIMIT` queries. Flutter requests pages near the top, merges them idempotently, preserves the pixel anchor and restores saved page count and offset per conversation.

## Epic 7 — images

| Item | Status |
|---|---|
| Pick JPEG, PNG or WebP | IMPLEMENTED |
| Re-encode without EXIF/GPS | IMPLEMENTED |
| Correct orientation | IMPLEMENTED |
| Compress to at most 50 KiB | IMPLEMENTED |
| Send through encrypted durable message queue | IMPLEMENTED |
| Image thumbnail and full-screen preview | IMPLEMENTED |
| Malformed payload placeholder | IMPLEMENTED |
| Explicit save to gallery | IMPLEMENTED |
| Dedicated encrypted attachment file storage | IMPLEMENTED |

Image transport remains compatible with the versioned encrypted 0.1 message body. Local materialization uses a dedicated AES-GCM file store whose 256-bit key is held in platform secure storage. The application supports manual or automatic local download, encrypted-cache removal, full-screen preview and explicit gallery export. Corrupt files or cache restored without its platform key are treated as disposable and never as message history. Storage tests verify encryption round-trip, no plaintext file equivalence, usage accounting, clearing and wrong-key recovery.

## Epic 8 — notifications

| Item | Status |
|---|---|
| Ignore protocol retransmission notifications | IMPLEMENTED |
| Message/pairing notification switches | IMPLEMENTED |
| Master, sound, vibration and preview switches | IMPLEMENTED |
| Android native preference enforcement | IMPLEMENTED |
| Deduplicate by message/pairing ID | IMPLEMENTED |
| Suppress current-conversation notification | IMPLEMENTED |
| Open exact conversation from alert | IMPLEMENTED |
| Clear notification after opening | IMPLEMENTED |
| Desktop native notification and restore window | IMPLEMENTED |

Desktop and Android use persistent ID deduplication, category preferences, active-conversation suppression, cold-start navigation to the exact conversation and alert clearing. Platform verification remains outstanding.

## Epic 9 — settings and privacy

| Item | Status |
|---|---|
| Current/retro and light/dark/system themes | IMPLEMENTED |
| Reduced motion | IMPLEMENTED |
| Read receipts switch, private default off | IMPLEMENTED |
| Typing and presence switches | IMPLEMENTED |
| Notification settings | IMPLEMENTED |
| Desktop tray/autostart settings | IMPLEMENTED |
| Automatic image download switch | IMPLEMENTED |
| Local data/cache usage and clear image cache | IMPLEMENTED |

Reduced motion is durable, rolls back optimistic UI on save failure and disables cyclic transport animation. Image settings expose private-by-default automatic download, encrypted-cache file/byte usage and confirmed cache clearing. Desktop autostart reads back the effective system value after every change.

## Epic 10 — release quality

| Item | Status |
|---|---|
| Component-local busy indicators | IMPLEMENTED |
| No global action strip | IMPLEMENTED |
| Responsive desktop workspace and splitter | IMPLEMENTED |
| Keyboard focus and shortcuts | IMPLEMENTED |
| Accessible semantics and contrast | IMPLEMENTED |
| Sanitized diagnostic ZIP | IMPLEMENTED |
| Database migrations preserve data | IMPLEMENTED |
| Clean install and upgrade validation | IMPLEMENTED |
| Windows end-to-end matrix | NOT_STARTED |
| Android end-to-end matrix | NOT_STARTED |

The shell provides keyboard navigation for chats, contacts, settings, account, reconnect and conversation close. Contact, image, relationship and transport controls expose screen-reader semantics. Material action foregrounds are selected by measured luminance, and regression tests require a contrast ratio of at least 4.5 across every theme family and retro palette.

Diagnostic export excludes databases, key stores, private-key files and binary artifacts and redacts message bodies, attachments, ciphertexts, tokens, credentials, onion addresses, PEM blocks and large base64/hex values before creating the ZIP.

The executable release matrix performs Rust/Flutter/Kotlin/Windows checks where available, Android clean install, reinstall with data-preservation marker, Android cold-start recovery, Windows clean-profile startup and same-profile restart. It records all results in JSON and fails when required platforms are absent. Real signed-candidate upgrade and cross-device E2E scenarios still require physical hosts.

## Release blockers

0.1 must not be tagged until these verification blockers are resolved:

1. Execute twenty symmetric pairing runs in both directions.
2. Verify text and image delivery through offline periods, reconnects and real process restarts on Windows and Android.
3. Verify relationship removal, history policy and fresh re-pair on both platforms.
4. Verify cursor pagination and notification routing on both platforms.
5. Run the full clean-install, signed-upgrade, cold-start, background and recovery matrices.
6. Run compilation, static analysis and all automated tests for the final commit.

Implementation is complete, but no `VERIFIED_WINDOWS`, `VERIFIED_ANDROID` or `DONE` status may be inferred until the executable and manual matrices pass.

## Acceptance criteria

1. Pairing succeeds symmetrically twenty consecutive times in both directions.
2. Pairing immediately produces trusted contacts and active conversations.
3. Text and image messages survive offline, reconnect and restart without loss or duplication.
4. Timeline behavior follows Epic 6.
5. Images contain no source metadata and never exceed 50 KiB before message encoding.
6. Notifications are deduplicated and never represent technical protocol events.
7. Removing a relationship terminates communication on both sides and allows a fresh future pairing.
8. Every asynchronous user action has a local busy or waiting state.
9. Windows and Android release matrices pass.
10. Logs contain no plaintext message, image payload or private key.
