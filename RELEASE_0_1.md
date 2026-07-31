# TorChat 0.1 — frozen release scope

Status values:

- `NOT_STARTED`
- `IN_PROGRESS`
- `BLOCKED`
- `IMPLEMENTED`
- `VERIFIED_WINDOWS`
- `VERIFIED_ANDROID`
- `DONE`

## Product definition

TorChat 0.1 is a reliable private 1:1 messenger for Windows and Android. The release is complete when two users can install the application, pair, communicate through temporary network failures, manage the contact relationship, exchange text and small images, receive correct notifications, and update the application without losing local data.

After this file is committed the feature set is frozen. Bug fixes and UX work inside the listed features are allowed. New product features go to 0.2.

## Explicitly excluded from 0.1

- audio and video calls
- voice messages
- arbitrary files
- protocol-level groups
- multi-device accounts and history synchronization
- edit or remote-delete sent messages
- emoji reactions
- disappearing messages
- public user search and public profiles
- cloud backup

## Trust model for 0.1

Entering a pairing code and explicitly accepting the request establishes the trusted contact relationship. No additional `Verify contact` action is required. Pairing completion must atomically produce a verified contact and an active conversation on both sides.

## Epic 1 — startup and lifecycle

| Item | Status |
|---|---|
| Deterministic sequential warmup | IMPLEMENTED |
| Restore local shell and snapshot after restart | IMPLEMENTED |
| Reliable reconnect without fatal network state | IN_PROGRESS |
| Desktop tray/background lifecycle | NOT_STARTED |
| Single desktop application instance | NOT_STARTED |
| Restore desktop window size and position | NOT_STARTED |

## Epic 2 — pairing

| Item | Status |
|---|---|
| Generate and rotate pairing code | IMPLEMENTED |
| Enter code manually | IMPLEMENTED |
| Scan QR code | IMPLEMENTED |
| Accept, reject and cancel pairing | IMPLEMENTED |
| Persist pairing control-plane state across reconnect | IN_PROGRESS |
| Pairing produces verified contacts automatically | IN_PROGRESS |
| Pairing produces active conversations automatically | IN_PROGRESS |
| Open the new conversation automatically after completion | IN_PROGRESS |
| Add deterministic local connection system event | NOT_STARTED |
| Prevent duplicate contacts and repeated acceptance | IN_PROGRESS |

## Epic 3 — contact lifecycle

| Item | Status |
|---|---|
| Local contact alias | IMPLEMENTED |
| Mute contact | IMPLEMENTED |
| Block contact | IMPLEMENTED |
| Contact context menu | NOT_STARTED |
| Remove contact on both sides | NOT_STARTED |
| Block sending immediately after relationship removal | NOT_STARTED |
| Preserve or delete local history by explicit choice | NOT_STARTED |
| Re-add removed contact using a fresh pairing and MLS state | NOT_STARTED |

## Epic 4 — conversations

| Item | Status |
|---|---|
| Optimistic conversation row | IMPLEMENTED |
| Conversation available immediately after pairing | IN_PROGRESS |
| Local conversation title | NOT_STARTED |
| Pin conversation | NOT_STARTED |
| Mute conversation | NOT_STARTED |
| Conversation context menu | NOT_STARTED |
| Clear local conversation history | NOT_STARTED |
| Local system events | NOT_STARTED |

## Epic 5 — text messaging

| Item | Status |
|---|---|
| Durable outgoing queue | IN_PROGRESS |
| Offline and reconnect delivery | IN_PROGRESS |
| Idempotent inbound processing | IN_PROGRESS |
| Queued, sending, sent, delivered, read and failed states | IMPLEMENTED |
| Reply to message | IMPLEMENTED |
| Copy message | IMPLEMENTED |
| Retry message | IMPLEMENTED |
| Delete message locally | IMPLEMENTED |
| Local search in current conversation | IMPLEMENTED |
| Persist sent, delivered and read timestamps | NOT_STARTED |

## Epic 6 — timeline and scrolling

| Item | Status |
|---|---|
| Open conversation at newest message | IN_PROGRESS |
| Auto-scroll when user is near the bottom | IN_PROGRESS |
| Never pull user away while reading older messages | NOT_STARTED |
| New-message counter and jump-to-bottom button | NOT_STARTED |
| Own sent message scrolls to bottom | IN_PROGRESS |
| Status changes do not move scroll position | NOT_STARTED |
| SQLite message pagination | NOT_STARTED |
| Preserve position while prepending older messages | NOT_STARTED |
| Restore per-conversation scroll position | NOT_STARTED |

## Epic 7 — images

| Item | Status |
|---|---|
| Pick JPEG, PNG or WebP image | NOT_STARTED |
| Strip EXIF and GPS metadata | NOT_STARTED |
| Correct orientation | NOT_STARTED |
| Compress to at most 50 KiB | NOT_STARTED |
| Encrypted local attachment storage | NOT_STARTED |
| Durable attachment delivery and retry | NOT_STARTED |
| Image bubble and thumbnail | NOT_STARTED |
| Full-screen local image preview | NOT_STARTED |
| Explicit save to gallery | NOT_STARTED |

## Epic 8 — notifications

| Item | Status |
|---|---|
| Deduplicate message notifications by message id | IN_PROGRESS |
| Deduplicate pairing notifications by pairing id | IN_PROGRESS |
| Never notify for protocol retransmissions | IN_PROGRESS |
| Suppress notification for currently open conversation | NOT_STARTED |
| Open exact conversation from notification | NOT_STARTED |
| Clear notification after opening conversation | NOT_STARTED |
| Per-contact mute | IMPLEMENTED |
| Message notification toggle | NOT_STARTED |
| Pairing notification toggle | NOT_STARTED |
| Sound toggle | NOT_STARTED |
| Vibration toggle | NOT_STARTED |
| Message preview privacy toggle | NOT_STARTED |
| Desktop native notification and window restore | NOT_STARTED |

## Epic 9 — settings and privacy

| Item | Status |
|---|---|
| Current and retro themes | IMPLEMENTED |
| Light, dark and system mode | IMPLEMENTED |
| Reduced motion | IN_PROGRESS |
| Read receipts toggle | NOT_STARTED |
| Typing indicator toggle | NOT_STARTED |
| Presence toggle | NOT_STARTED |
| Automatic image download toggle | NOT_STARTED |
| Notification settings | NOT_STARTED |
| Desktop tray settings | NOT_STARTED |
| Local data and cache usage | NOT_STARTED |
| Clear local image cache | NOT_STARTED |

## Epic 10 — release quality

| Item | Status |
|---|---|
| Component-local busy indicators | IN_PROGRESS |
| No layout overflow at supported sizes | IN_PROGRESS |
| Keyboard focus and shortcuts | NOT_STARTED |
| Accessible semantics and contrast | IN_PROGRESS |
| Sanitized diagnostic ZIP | IN_PROGRESS |
| Database migrations preserve data | NOT_STARTED |
| Clean install validation | NOT_STARTED |
| Upgrade validation | NOT_STARTED |
| Windows end-to-end test matrix | NOT_STARTED |
| Android end-to-end test matrix | NOT_STARTED |

## Release acceptance criteria

0.1 may be tagged only when all of the following are verified:

1. Pairing succeeds symmetrically twenty consecutive times in both directions.
2. Pairing immediately produces verified contacts and active conversations on both devices.
3. The new conversation opens automatically after pairing.
4. Text messages survive offline periods, reconnects and application restarts without loss or duplication.
5. Timeline scrolling follows the user-friendly rules in Epic 6.
6. Images are stripped of metadata, encrypted locally and never exceed 50 KiB on the wire.
7. Notifications are deduplicated and never represent technical protocol events.
8. Removing a contact terminates the relationship on both sides and prevents further messages.
9. A removed contact can be paired again only through a fresh cryptographic relationship.
10. Every asynchronous user action has a local busy or waiting state.
11. Windows and Android cold-start, upgrade and recovery scenarios pass.
12. Logs and diagnostic archives contain no plaintext messages, attachment content or private keys.
