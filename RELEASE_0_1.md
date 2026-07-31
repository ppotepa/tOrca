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

Entering a pairing code and explicitly accepting the request establishes trust. Pairing completion must produce a verified contact and active conversation on both sides. No second manual verification action is required.

## Epic 1 — startup and lifecycle

| Item | Status |
|---|---|
| Deterministic sequential warmup | IMPLEMENTED |
| Restore local shell and snapshot after restart | IMPLEMENTED |
| Reliable reconnect without fatal network state | IN_PROGRESS |
| Persist desktop size and position | IMPLEMENTED |
| Close desktop window to background | IMPLEMENTED |
| Desktop tray with show, settings and exit | IMPLEMENTED |
| Single desktop application instance | IMPLEMENTED |
| Desktop autostart setting | IN_PROGRESS |
| Desktop lifecycle verified on Windows | NOT_STARTED |

The desktop lifecycle is now initialized before the Flutter application starts. A loopback activation socket prevents a second process from starting a competing Tor/storage runtime and restores the existing window instead. Closing the window hides it only after the tray is ready. These paths remain unverified until Windows CI or user-provided local results are available.

## Epic 2 — pairing

| Item | Status |
|---|---|
| Generate, enter and scan pairing code | IMPLEMENTED |
| Accept, reject and cancel pairing | IMPLEMENTED |
| Persist control-plane state across reconnect | IN_PROGRESS |
| Automatically trust newly paired contacts | IMPLEMENTED |
| Automatically activate conversation | IMPLEMENTED |
| Automatically open new conversation | IMPLEMENTED |
| Prevent duplicate acceptance and contacts | IN_PROGRESS |
| Deterministic local connection system event | IN_PROGRESS |
| Twenty symmetric pairing runs per direction | NOT_STARTED |

## Epic 3 — contact lifecycle

| Item | Status |
|---|---|
| Local alias, mute and block | IMPLEMENTED |
| Contact details and transport controls | IMPLEMENTED |
| Contact context menu | IN_PROGRESS |
| Versioned ContactRemoved wire payload | IMPLEMENTED |
| Transactional local relationship removal | IN_PROGRESS |
| Remote relationship removal | IN_PROGRESS |
| Block sending after removal | IN_PROGRESS |
| Preserve/delete history choice | IN_PROGRESS |
| Fresh re-pair and MLS state after removal | IN_PROGRESS |

The core exposes a dedicated versioned `ContactRemovedPayloadV1` contract with a stable message ID, removal timestamp and history policy. It remains transported inside the existing encrypted durable message channel so older clients and intermediate commits keep an exhaustive `ApplicationPayloadV1` contract. Relationship storage atomically writes the tombstone, disables the contact, stops all ordinary queued messages, removes MLS and peer endpoint state, and applies the local history policy while preserving only the durable removal delivery. The application additionally deletes every ordinary `QUEUED` or `SENDING` message through the existing runtime API after either local or remote removal, preventing older runtime implementations from resuming stale traffic after reconnect. Remote reconciliation reads the real durable message list instead of relying on conversation preview. A newly completed and verified pairing records a fresh relationship boundary, so retained removal events from an older relationship cannot terminate the new conversation. Engine-level tombstone routing and Windows/Android verification remain in progress.

## Epic 4 — conversations

| Item | Status |
|---|---|
| Optimistic conversation row | IMPLEMENTED |
| Local title | IMPLEMENTED |
| Pin conversation | IMPLEMENTED |
| Mute conversation | IMPLEMENTED |
| Archive conversation locally | IMPLEMENTED |
| Desktop/mobile context menu | IMPLEMENTED |
| Clear local history | IN_PROGRESS |
| Local system events | IN_PROGRESS |

## Epic 5 — text messaging

| Item | Status |
|---|---|
| Durable outgoing queue | IN_PROGRESS |
| Offline and reconnect delivery | IN_PROGRESS |
| Idempotent inbound processing | IN_PROGRESS |
| Queued/sending/sent/delivered/read/failed states | IMPLEMENTED |
| Reply, copy, retry and local delete | IMPLEMENTED |
| Local search in current conversation | IMPLEMENTED |
| Persist sent/delivered/read timestamps | NOT_STARTED |

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

The runtime now reads the newest 50 SQLite rows by default and exposes older pages through a stable `(created_at, id)` cursor using bounded `LIMIT` queries. Flutter requests those pages only when the reader reaches the top, merges them idempotently, preserves the pixel anchor across prepend, and restores the saved visible page count and scroll offset per conversation. Relationship cleanup uses an explicit full-history storage mode so pagination cannot leave queued messages or retained history behind. This path remains unverified until Rust/Flutter CI or user-provided local results are available.

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
| Explicit save to gallery | NOT_STARTED |
| Dedicated encrypted attachment file storage | NOT_STARTED |

0.1 currently uses a versioned image-message body in the encrypted message pipeline. A dedicated attachment table/blob store remains future hardening.

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

Desktop notifications use persistent ID deduplication, suppress a toast when its conversation is already selected, respect master/message/preview preferences, restore the window, open the exact conversation and close the selected alert. Android now applies the same category preferences and persistent deduplication in the foreground service, reads the active Flutter conversation from shared preferences, embeds the conversation and notification identifiers in `PendingIntent`, buffers cold-start clicks until the event channel attaches, opens the exact conversation and clears the native alert. These paths remain unverified until Windows and Android builds or user-provided local results are available.

## Epic 9 — settings and privacy

| Item | Status |
|---|---|
| Current/retro and light/dark/system themes | IMPLEMENTED |
| Reduced motion | IN_PROGRESS |
| Read receipts switch, private default off | IMPLEMENTED |
| Typing and presence switches | IMPLEMENTED |
| Notification settings | IMPLEMENTED |
| Desktop tray/autostart settings | IN_PROGRESS |
| Automatic image download switch | NOT_STARTED |
| Local data/cache usage and clear image cache | NOT_STARTED |

## Epic 10 — release quality

| Item | Status |
|---|---|
| Component-local busy indicators | IMPLEMENTED |
| No global action strip | IMPLEMENTED |
| Responsive desktop workspace and splitter | IMPLEMENTED |
| Keyboard focus and shortcuts | IN_PROGRESS |
| Accessible semantics and contrast | IN_PROGRESS |
| Sanitized diagnostic ZIP | IN_PROGRESS |
| Database migrations preserve data | NOT_STARTED |
| Clean install and upgrade validation | NOT_STARTED |
| Windows end-to-end matrix | NOT_STARTED |
| Android end-to-end matrix | NOT_STARTED |

## Release blockers

0.1 must not be tagged until these blockers are resolved and verified:

1. Transactional relationship removal and fresh re-pair identity.
2. SQLite message pagination with scroll-position preservation.
3. Durable and idempotent message/pairing delivery verified through restarts.
4. Notification deduplication and deep-link behavior.
5. Windows and Android clean-install, upgrade, cold-start and recovery matrices.
6. Local compilation and static analysis for all newly added Flutter, Kotlin and Rust code.

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
