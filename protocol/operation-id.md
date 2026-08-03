# Stable operation IDs

`requestId` identifies one transport/UI attempt. `commandId` identifies the
logical mutation and must survive timeout, retry, process recreation and host
reconnect. The engine stores the command payload digest together with the
result; reusing an ID with a different payload is an idempotency conflict.

## Mutating commands

| Command | Stable identity used by the host |
| --- | --- |
| `send_message` | a new UUID per logical message; reuse it only when retrying that message |
| `delete_message` | `delete:<messageId>` |
| `submit_pairing_code` | a new UUID per submitted code attempt |
| `accept_pairing`, `reject_pairing`, `cancel_pairing`, `archive_pairing` | `pairing:<pairingId>:<operation>` |
| `verify_contact`, `update_contact_settings`, `remove_relationship`, `request_relationship_removal` | `contact:<installationId>:<operation>` |
| `start_conversation` | `conversation:<contactId>:start` |
| `set_nickname` | a new UUID per requested profile mutation |
| `refresh_pairing_code`, endpoint/capability rotate/revoke | a new UUID per logical request |
| `retry_dead_letter` | `dead-letter:<kind>:<id>:retry` |

Read-only commands do not need a durable operation ID. Reconnecting hosts may
use a new `requestId` while retaining the same `commandId` for a mutation.

The stable ID must not be derived from `requestId`, current time, widget
instance, or connection generation. The engine remains the authority for
payload conflict detection and durable replay.
