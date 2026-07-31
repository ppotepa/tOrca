# TorChat 0.1 implementation progress

This file records implementation commits after the feature freeze in `RELEASE_0_1.md`.
`IMPLEMENTED` means code is present on `main`. It does not mean the feature has passed Windows or Android qualification.

## Implemented increments

| Area | Status | Commit |
|---|---|---|
| Frozen 0.1 release scope | IMPLEMENTED | `9a0b3139` |
| Automatic trust and conversation opening after pairing | IMPLEMENTED | `7c37888e` |
| Pairing auto-trust contract tests | IMPLEMENTED | `cc1fc2d2` |
| Release chat scroll policy | IMPLEMENTED | `aa5ec026` |
| Activate release chat on desktop and mobile | IMPLEMENTED | `abaa1dd0` |
| Persistent local conversation preferences | IMPLEMENTED | `2932efb7` |
| Unicode-safe local conversation titles | IMPLEMENTED | `31a6c534` |
| Conversation context menu, pin, mute and archive | IMPLEMENTED | `6b87fa1d` |
| Context-menu control-flow hardening | IMPLEMENTED | `9e88a9a9` |
| Image and file picker dependencies | IMPLEMENTED | `b411c666` |
| Metadata-free 50 KiB image codec | IMPLEMENTED | `e999050f` |
| Cross-platform image picker | IMPLEMENTED | `d7856ba6` |
| Image bubble and full-screen preview | IMPLEMENTED | `6657bc84` |
| Active chat image send integration | IMPLEMENTED | `fe2515b1` |
| Safe image preview labels | IMPLEMENTED | `ca9eea37` |
| Image codec regression tests | IMPLEMENTED | `1536bd90`, `cb0ee892` |
| Android notification preference policy | IMPLEMENTED | `19175342` |
| Android event-pump preference enforcement | IMPLEMENTED | `a9c3e764` |
| Process context for notification policy | IMPLEMENTED | `63d659ae` |
| Separate message-notification setting | IMPLEMENTED | `58bfa12e` |
| Privacy-first read-receipt default | IMPLEMENTED | `fe7f51ca` |
| Contact context menu | IMPLEMENTED | `6ff8246b` |
| Desktop window size and position persistence | IMPLEMENTED | `d45e6a95` |
| Desktop lifecycle initialization | IMPLEMENTED | `c380e003` |
| Recoverable desktop close behavior | IMPLEMENTED | `c818e235` |
| Durable encrypted relationship-removal sentinel | IMPLEMENTED | `c68dc695`, `cfb33572` |
| Relationship removal system-event rendering | IMPLEMENTED | `d038e222` |
| Relationship-removal format tests | IMPLEMENTED | `0cd7cbcc` |
| Durable relationship tombstone storage | IMPLEMENTED | `d9e717c7`, `e0a0f353` |
| Relationship storage tests and hardening | IMPLEMENTED | `ad04ff47`, `ed8bce92` |
| Remove incomplete parallel core removal variant | IMPLEMENTED | `686edb03` |
| Release validation workflow | IMPLEMENTED | `387da850` |
| Application version 0.1.0+1 | IMPLEMENTED | `fcc7a1f9` |

## Still in progress

- explicit preserve/delete-history choice during contact removal UI
- physical actor integration of relationship tombstones
- safe re-pairing with fresh MLS state after tombstone
- system events for contact connected and re-added
- persisted `sentAt`, `deliveredAt` and `readAt`
- SQLite message pagination and stable prepend scroll position
- per-conversation scroll restoration
- suppressing notifications for the currently visible conversation
- notification deep-linking and clearing
- packaged desktop tray icon and tray menu
- desktop single-instance enforcement and launch-at-startup UI
- desktop native notifications
- local image cache accounting and explicit cache clearing
- full release-quality and migration test matrix

## Qualification state

No listed feature may be marked `DONE` until both Windows and Android validation has completed where applicable.
Current GitHub commits do not yet have confirmed CI results attached, so all entries above remain unverified.
