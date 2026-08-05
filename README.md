# Torca

Torca is an experimental private 1:1 messenger for Windows and Android. It uses
local installation identities, Tor onion services, MLS-protected message content
and local encrypted storage. No phone number, email address or public user
directory is required.

> [!WARNING]
> Torca 0.2 is a test release. Protocols, storage formats and user interfaces may
> change. Torca does not guarantee anonymity against compromised devices, global
> traffic analysis, operating-system compromise or Tor network vulnerabilities.

## Current product scope

The Torca 0.2 test release covers:

- local installation identity and profile;
- pairing by short-lived code or QR code with explicit approval;
- private contacts and 1:1 conversations;
- text messages, replies, delivery receipts and read receipts;
- image attachments with local encrypted caching;
- per-contact P2P onion delivery with capability authentication;
- direct onion P2P delivery with local durable retry;
- local SQLCipher-compatible persistence;
- Windows and Android clients sharing the Rust runtime and Flutter UI.

Calls, groups, multi-device synchronization, public discovery and cloud backup
are outside the 0.2 scope.

Accepting a pairing request establishes a verified contact and an active
conversation on both sides. No additional verification action is required.

## Privacy and trust model

Client devices own identities, private keys, MLS state, contact relationships
and conversation history. The relay is untrusted infrastructure used only for
pairing. It forwards opaque pairing blobs while both devices are active, but
must not receive plaintext messages or client private keys.

The relay is an ephemeral rendezvous broker. It stores active pairing slots and
bridges only in process memory; it has no database or offline mailbox.

Contact delivery uses direct P2P through Tor:

```text
Client A -> local Tor -> contact onion endpoint -> Client B
```

A connected peer link does not by itself mean that a contact is active in the
application. Presence, conversation focus, peer connectivity and endpoint
capability are separate aspects of contact state.

See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md) and
[docs/security/threat-model.md](docs/security/threat-model.md) before using a
test build with sensitive information.

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

Mutations require a stable `command_id` so retries remain idempotent.

## Repository layout

Internal crate and package identifiers retain the historical `torchat-*` prefix
for source compatibility. The product and user-facing application name is
**Torca**.

- `common/torchat-core` — identities, protocol types and MLS primitives.
- `packages/torchat-runtime` — domain workflows and projections.
- `packages/torchat-client-engine` — actor, persistence, retry and transports.
- `packages/torchat-client-engine-ffi` — native ABI for platform hosts.
- `apps/mobile/flutter` — shared Flutter client and Android host integration.
- `apps/desktop/flutter` — Windows Flutter composition root.
- `packages/torchat-flutter-ui` — shared theme and presentation primitives.
- `packages/torchat-domain` — runtime-independent domain vocabulary and rules.
- `packages/torchat-crypto` — cryptographic primitives.
- `apps/desktop/native` — Windows native runtime bridge.
- `services/torchat-relay` — in-memory untrusted pairing rendezvous broker.
- `infra` — Docker and Tor deployment configuration.
- `scripts` — development, deployment and validation entrypoints.

## Release version

`release/version.json` is the canonical source for the product version, build
number and release channel. Rust and Flutter manifests must match it. Validate
consistency with:

```powershell
.\scripts\release\check-release-version.ps1
```

The initial 0.2 test channel starts at `0.2.0-beta.1`.

## Development

Prerequisites include Rust, Flutter, an Android SDK when building Android,
PowerShell 7 and Docker for the local relay/Tor stack.

The supported public entrypoint remains:

```powershell
.\scripts\torchat.ps1 help
```

Common operations:

```powershell
.\scripts\torchat.ps1 status all
.\scripts\torchat.ps1 stack start
.\scripts\torchat.ps1 deploy android -Device auto
.\scripts\torchat.ps1 deploy all
```

See [scripts/README.md](scripts/README.md) for command targets, policies,
emulator usage and diagnostics.

## License

Torca is licensed under the GNU Affero General Public License version 3 or, at
your option, any later version. See [LICENSE](LICENSE). Third-party components
retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
