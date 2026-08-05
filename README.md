# TorChat

TorChat is an experimental private 1:1 messenger for Windows and Android. It
uses local installation identities, Tor onion services, MLS-protected message
content and local encrypted storage. No phone number, email address or public
user directory is required.

> [!WARNING]
> TorChat is under active development. Protocols, storage formats and user
> interfaces may change. It does not guarantee anonymity against compromised
> devices, global traffic analysis, operating-system compromise or Tor network
> vulnerabilities.

## Current product scope

The current release scope covers:

- local installation identity and profile;
- pairing by short-lived code or QR code with explicit approval;
- private contacts and 1:1 conversations;
- text messages, replies, delivery receipts and read receipts;
- per-contact P2P onion delivery with capability authentication;
- direct onion P2P delivery with local durable retry;
- local SQLCipher-compatible persistence;
- Windows and Android clients sharing the Rust runtime and Flutter UI.

Calls, groups, multi-device synchronization, public discovery and cloud backup
are not part of the current scope.

Accepting a pairing request establishes a verified contact and an active
conversation on both sides. No additional `Verify contact` action is required.

## Privacy and trust model

Client devices own identities, private keys, MLS state, contact relationships
and conversation history. The relay is untrusted infrastructure: it handles
pairing only. It forwards opaque pairing blobs while both devices are active,
but must not receive plaintext messages or client private keys.

The relay is an ephemeral rendezvous broker. It stores only active pairing
slots and bridges in process memory; it has no database or offline mailbox.

Contact delivery always uses direct P2P:

```text
Client A -> local Tor -> contact onion endpoint -> Client B
```

A connected peer link does not by itself mean that the contact is active in the
application. Presence, conversation focus, peer connectivity and endpoint
capability are separate aspects of contact state.

## Architecture

```text
Flutter UI
    |
runtime bridge / generated contract
    |
Rust ClientEngine actor
    |
Rust domain runtime
    |
SQLCipher-compatible SQLite + MLS state
    |
Tor peer transport and ephemeral pairing rendezvous
```

The actor serializes state transitions. The runtime owns domain rules. Storage
owns SQL and transactions. Flutter renders snapshots and submits typed commands;
it does not implement a second messaging, pairing or probing state machine.

SQL is kept as parameterized files:

- SQLite uses `?1`, `?2`, ...;
- queries, commands and migrations have separate roots;
- `include_str!` embeds SQL at compile time;
- actor and UI code do not access raw database connections.

The Rust API also exposes flat typed helpers for common operations, for example
`client.list_pairings()` and `client.list_messages(conversation_id)`. Mutations
require a stable `command_id` so retries remain idempotent.

## Repository layout

- `common/torchat-core` — identities, protocol types and MLS primitives.
- `packages/torchat-runtime` — domain workflows and projections.
- `packages/torchat-client-engine` — actor, persistence, retry and transports.
- `packages/torchat-client-engine-ffi` — native ABI for platform hosts.
- `apps/mobile/flutter` — Flutter UI and Android host integration.
- `packages/torchat-flutter-ui` — shared Flutter theme and presentation primitives.
- `packages/torchat-domain` — runtime-independent client-domain vocabulary and rules.
- `packages/torchat-crypto` — pure cryptographic primitives for pairing.
- `apps/desktop/native` — Windows host and runtime bridge.
- `services/torchat-relay` — in-memory untrusted pairing rendezvous broker.
- `infra` — Docker and Tor deployment configuration.
- `scripts` — development, deployment and validation entrypoints.

## Development

Prerequisites include Rust, Flutter, an Android SDK when building Android,
PowerShell 7 and Docker for the local relay/Tor stack.

The supported public entrypoint is:

```powershell
.\scripts\torchat.ps1 help
```

Common operations:

```powershell
# Inspect the environment
.\scripts\torchat.ps1 status all

# Start the local stack without rotating onion identity or deleting data
.\scripts\torchat.ps1 stack start

# Build, install and run Android on a selected emulator/device
.\scripts\torchat.ps1 deploy android -Device auto

# Deploy all supported clients
.\scripts\torchat.ps1 deploy all
```

See [scripts/README.md](scripts/README.md) for command targets, policies,
emulator usage and diagnostics.

## License

No license has been declared yet. Do not assume redistribution rights until a
license file is added.
