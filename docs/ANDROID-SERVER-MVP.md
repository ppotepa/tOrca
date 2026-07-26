# TorChat Android + Server MVP

## Product scope

The first release contains one Android client and one Tor-hosted delivery server.

- No email, phone number or password registration.
- On first launch, the app creates an anonymous installation identity.
- Users can choose a display name, but it is not the cryptographic identity.
- The app can use the built-in default onion address or a user-entered custom onion address.
- The interface should feel familiar to Telegram: conversation list, chat screen, unread counters, message states, attachments later and a settings/security screen.

The first release should support text messages and direct conversations. Groups, multiple devices and attachments are designed into the protocol but can be enabled after the direct-chat path is stable.

## Important change: no hardware fingerprint

We should not collect IMEI, serial number, Android ID, advertising ID, MAC address or a hardware fingerprint. These values are either unavailable/restricted, resettable, identifying or inappropriate for a privacy messenger. A virtual machine can also imitate many device properties.

Instead, each installation creates a random non-exportable signing key:

```text
installation_id = hash(public_installation_key)
fingerprint     = human-readable hash(public_installation_key)
```

The server sees the public key and a pseudonymous installation ID. It never sees the private key. The key is stored in Android Keystore and, when available, generated with hardware-backed protection. Android supports key attestation for checking whether a key is hardware protected, but that is evidence about key storage, not a guarantee that the whole device is safe. [Android key attestation](https://developer.android.com/privacy-and-security/security-key-attestation)

This prevents a normal reinstall from preserving the same identity, unless we deliberately add a recovery mechanism. That trade-off is preferable for privacy. Abuse controls must not rely on one permanent device identifier.

## Abuse and spam controls

The server should combine several low-privacy-cost controls:

1. Per-installation-key quotas with exponential backoff.
2. Per-onion-service global quotas and queue limits.
3. Server-issued signed capability tokens for sending or creating a conversation.
4. A lightweight proof-of-work challenge only when behaviour is suspicious.
5. Message size, attachment and fan-out limits.
6. Local abuse reports that contain a selected ciphertext envelope, not a server-side plaintext log.
7. Optional Android Play Integrity checks for the official Play-distributed build.

Play Integrity can provide signals about an unmodified app, certified devices and emulated/risky environments, but it requires Google Play services and is not suitable as the only identity mechanism. Users outside Google Play, on custom ROMs or without Play services need a documented fallback. [Play Integrity overview](https://developer.android.com/google/play/integrity/overview)

We can require stronger integrity only for high-risk actions, such as creating many new conversations, rather than blocking every VM by default. A determined attacker can still automate a real device, so rate limits remain necessary.

## Server trust model

The server is a delivery service, not a trusted chat participant. It can:

- register public installation keys;
- publish public conversation invitations/KeyPackages;
- authenticate and relay signed encrypted envelopes while both peers are online;
- apply quotas and reject malformed requests;
- know approximate timing, ciphertext sizes, queue destinations and active installation keys.

The server cannot:

- read message text or attachments;
- derive conversation keys;
- recover a private installation key;
- silently replace a verified contact key without client warnings;
- decrypt an offline queue after a database leak.

## Onion configuration

### Default server

The production onion address is compiled into the release configuration and displayed in the About/Security screen. The client accepts only the exact configured v3 onion address. The onion address itself is tied to the onion service identity, giving the client a stable service identity and encrypted Tor transport.

### Custom server

On first launch, the user may enter a 56-character v3 `.onion` address. The app must show a clear warning:

> This is a custom server. Tor protects the connection, but TorChat cannot vouch for the operator or its availability.

For a custom server, the first successful connection pins that onion address locally. A later change requires explicit confirmation. The custom server is still unable to decrypt E2EE messages, but it can refuse delivery, observe metadata and provide a different service policy.

No DNS, clearnet fallback, analytics endpoint, crash SDK or remote image host may be contacted. Android Network Security Configuration should disable accidental cleartext traffic and constrain trusted connections where applicable. [Android Network Security Configuration](https://developer.android.com/privacy-and-security/security-config)

## Android application layers

```text
Compose UI
    |
Application layer / ViewModels
    |
Tor transport + API client       Local encrypted repository
    |                             |
Rust FFI protocol core --------- SQLCipher SQLite
    |
Keystore-backed identity and conversation secrets
```

### Kotlin layer

- Jetpack Compose and ViewModel for UI.
- Kotlin Coroutines and Flow for state and message streams.
- Room/SQLite API over SQLCipher for local data.
- A narrow Rust C ABI consumed through Dart FFI; UI code never handles raw
  private keys.
- A Tor SOCKS5 transport adapter for the first MVP. The transport must route every application request through Tor.

### Rust core

- identity generation and signatures;
- fingerprint calculation and QR payloads;
- MLS state machine wrapper;
- canonical serialization and envelope validation;
- attachment encryption later;
- cross-platform unit tests, property tests and fuzz targets.

The app must use a maintained MLS implementation and audited cryptographic primitives. Rust core code should expose high-level operations such as `create_identity`, `create_invite`, `accept_invite`, `encrypt_message` and `decrypt_message`, not arbitrary key export functions.

## First-run flow

1. Display the default onion address and a Custom server option.
2. Start/attach to Tor and connect to the selected onion.
3. Generate a fresh installation key in Android Keystore.
4. Request a server challenge.
5. Sign the challenge with the installation key; optionally attach a Play Integrity verdict.
6. Server creates an anonymous installation record and returns a short-lived session token.
7. App displays the local fingerprint and recovery warning.
8. User chooses a display name locally and starts or joins a conversation by QR/invite code.

No account password is needed. If backup/recovery is added later, it must be an explicit encrypted export protected by a user secret; the server must never receive the secret or plaintext key.

## Contact and direct-chat flow

1. Alice shows an invite QR containing a random conversation ID, Alice's public credential and a signed KeyPackage.
2. Bob scans it through the Tor-connected app.
3. Bob verifies Alice's fingerprint in person or through a trusted channel.
4. Bob creates the two-member MLS group and sends the encrypted Welcome/Commit envelope.
5. The server forwards the opaque Welcome only if Alice is connected; otherwise
   Bob keeps it in the client-local encrypted pending queue.
6. Alice accepts and verifies the group state locally.
7. Messages are encrypted, signed/authenticated and stored locally before delivery.

For a direct chat, use a two-member MLS group rather than inventing a second 1:1 protocol. MLS is designed for asynchronous group key establishment, forward secrecy and post-compromise security. [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)

## API surface

All endpoints are reachable only through the configured onion service.

```text
POST /v1/bootstrap/challenge
POST /v1/installations
POST /v1/installations/integrity
GET  /v1/contacts/{opaque-id}/key-packages
GET  /v1/events                 # authenticated SSE/WebSocket stream
POST /v1/abuse/challenge
```

Every state-changing request contains a nonce, timestamp, request hash and installation signature. Session tokens are random, short-lived, stored hashed server-side and never logged. The server rejects replayed request IDs.

## Database tables

```text
installations
  installation_id, public_key, key_attestation_status,
  created_at, quota_bucket, revoked_at

key_packages
  package_id, installation_id, package_bytes, expires_at, consumed_at

conversation_routes
  route_id, recipient_installation_id, opaque_conversation_tag,
  created_at, revoked_at

rate_limits / abuse_events
  pseudonymous installation reference, action class, counters,
  expiry and reason code; never message plaintext
```

There is no retention policy for envelopes because the server does not persist
them. Do not store message previews, searchable plaintext, address books,
contact graphs or exact client IP addresses in application logs.

## Notifications

For the first MVP, foreground/background polling over Tor is simplest. Android push notifications can be added later, but FCM exposes timing and a device token to Google. If enabled, send only a generic wake-up signal; never send sender name, message text, conversation ID or ciphertext in the push payload.

## Delivery and deployment

```text
Android app -> Tor SOCKS5 -> v3 onion service -> API
                                             |
                                    PostgreSQL (installations/sessions only)
```

- API binds to `127.0.0.1` or a private container network.
- Tor owns the only public service entry point.
- PostgreSQL is not internet reachable.
- Secrets and onion private keys are mounted as protected volumes.
- Separate staging and production onion services.
- Server logs are minimized, rotated and encrypted at rest.
- Backups contain installation/session operational data only; access is audited.

## MVP acceptance criteria

- Two Android installations can create identities without registration.
- Users can compare fingerprints using QR and a short human-readable code.
- Alice and Bob can exchange messages while the server sees only ciphertext.
- Server database inspection cannot reveal plaintext.
- Tampering, replay and wrong-recipient envelopes are rejected.
- Custom onion addresses work without any clearnet fallback.
- A revoked installation cannot receive future conversation epochs.
- Rate limits work without collecting hardware identifiers.
- App runs with no Google Play services, with Play Integrity treated as optional.
