# TorChat architecture

## Components

```text
                         Tor network
                              |
                    v3 onion service gateway
                              |
       +----------------------+----------------------+
       |                     API                    |
       | accounts | device directory | delivery     |
       +----------------------+----------------------+
                              |
                    PostgreSQL + encrypted blobs

 Android / Rust core       iOS / Rust core
 key storage, MLS,         key storage, MLS,
 local DB, UI               local DB, UI
```

The gateway and API may be deployed together initially. The server must never receive private keys, plaintext, recovery secrets or a decryptable backup.

## Identity and fingerprints

An account is a stable random account identifier plus a user-chosen display name. The server may index the display name, but it is not the cryptographic identity.

Each installation creates:

- an account identity signing key;
- a device signing/encryption key pair;
- an MLS KeyPackage for inviting the device to conversations;
- local ratchet and conversation state.

The app derives a human-verifiable fingerprint from the account/device public credentials, displays it as grouped words and a QR code, and lets users compare it in person or through a trusted channel. A changed fingerprint produces a prominent warning and does not silently re-authenticate the device.

For multi-device accounts, the security view lists every device. Adding a device requires approval from an existing trusted device or an explicit recovery flow. The server can publish key material, but clients must verify signatures and the expected account binding.

## Conversation protocol

Use MLS for both direct conversations and groups. A direct chat is a two-member MLS group; this keeps membership changes, device removal, forward secrecy and post-compromise recovery on one model. The server forwards in-memory only:

- encrypted application messages;
- opaque delivery receipts, if enabled.

KeyPackages and Welcome data are exchanged through QR/direct client channels in
the first version. If the recipient is offline, the relay returns
`recipient_offline`; the sender may retry from its local encrypted queue.

The client encrypts message content, attachments, reactions and typing indicators where practical. Unencrypted metadata must be documented field by field.

When a member or device is added/removed, the group advances to a new epoch. A removed device must not be able to decrypt future messages. Clients periodically issue key updates to provide post-compromise recovery.

## Account and device flows

### Registration

1. Client creates the identity and first device locally.
2. Client sends a blinded/random account handle, public credential and signed device registration to the server.
3. Server creates the account and returns a session credential.
4. Client uploads signed KeyPackages for future asynchronous invitations.

### Login

Authentication is separate from E2EE. Use a random device credential protected by the platform keystore; do not use a password as a cryptographic identity. If passwords are supported, store only an Argon2id verifier and rate-limit attempts.

### New device

The new device creates fresh keys. An existing device approves it by sending an encrypted, signed provisioning package or the user completes a recovery flow. The server never sees the package plaintext.

### Message delivery

The sender creates an MLS ciphertext and an opaque client-generated message ID.
The server forwards it only while both authenticated WebSocket connections are
active and acknowledges forwarding without decrypting it. There is no server
queue, retry store or ciphertext persistence.

## Server data model

The first schema should contain:

- `accounts`: random ID, username/display-name index, timestamps, status;
- `devices`: account ID, device ID, signed public credential, last-seen bucket, revocation status;
- `key_packages`: device ID, package bytes, consumed flag, expiry;
- no `envelopes` table: relay frames exist only in process memory;
- `sessions`: hashed session tokens, expiry and revocation metadata.

Do not store plaintext contacts, conversation names, message previews, search indexes or address-book uploads. Attachments should use client-side encrypted random object keys and opaque storage IDs.

## Tor and networking

The mobile app should use a Tor-capable networking layer and pin the configured onion address/public service identity. No DNS fallback, analytics, crash-reporting network call or third-party asset may bypass Tor. Push notifications are a special privacy trade-off: APNs/FCM can reveal timing and device metadata, so the initial version should use a generic wake-up token and document the remaining leakage.

Tor hides the network location of the client and server, while E2EE protects message content. These are different protections and must be tested separately.

## Build phases

1. Rust protocol-core crate: identity, fingerprints, MLS wrapper, serialization and test vectors.
2. Local-only Android/iOS demo: create identity, compare fingerprints, create a direct conversation, encrypt/decrypt offline.
3. Untrusted delivery server: installations, sessions and ephemeral WebSocket delivery; server tests assert it never needs plaintext or message storage.
4. Tor integration and two-device testing.
5. Encrypted attachments, receipts and multi-device approval.
6. External cryptographic review, fuzzing, dependency review and a documented security release process.
