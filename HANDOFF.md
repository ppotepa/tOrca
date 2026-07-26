# TorChat handoff

Updated: 2026-07-26

## Project goal

TorChat is a privacy-oriented Flutter mobile messenger with a Tor onion-service backend. The server is an untrusted delivery service. Message contents, attachments and conversation keys must remain on clients and be protected with end-to-end encryption.

Current first-release scope:

- Flutter mobile client, Android first;
- Rust server and PostgreSQL;
- built-in default onion address plus optional custom `.onion` address;
- no email, phone number or password registration;
- anonymous installation identity;
- direct one-to-one text chat first;
- groups, attachments, push notifications and multi-device support later.

## Repository

Location: `D:\git\torchat`

```text
torchat/
├── apps/mobile/              # Flutter mobile client
├── clients/torchat-desktop/  # Slint desktop client for Windows/Linux
├── crates/torchat-core/       # shared Rust security/protocol core
├── server/torchat-server/     # Rust delivery server
├── protocol/                  # protocol contract placeholder
├── infra/                     # Docker, Tor and deployment configuration
├── tests/                     # test layout placeholder
├── docs/                      # architecture, MVP, threat model, deployment
├── Cargo.toml                 # Rust workspace
├── Cargo.lock                 # committed lockfile
├── CONTRIBUTING.md
├── SECURITY.md
└── HANDOFF.md                 # this file
```

The old browser prototype is in `D:\Git\tools\torgram`. It is not production-safe and is not part of this implementation.

## Key decisions

### Identity and fingerprint

Do not collect IMEI, serial number, MAC address, advertising ID or a hardware fingerprint. Those identifiers are privacy-invasive, restricted/resettable and do not reliably prevent virtual machines or automation.

Each installation should generate a random signing key. The public key is registered with the server; the private key remains in Android Keystore and is never sent to the server.

```text
installation_id = hash(public_installation_key)
fingerprint     = human-readable hash(public_installation_key)
```

The fingerprint is displayed as a short code and QR code. Hardware-backed key attestation may be an optional abuse signal, not the identity itself.

### E2EE

Use a maintained implementation of MLS (RFC 9420) for direct chats and future groups. A direct chat is a two-member MLS group. Do not implement cryptographic primitives or a custom ratchet in application code.

The server must never contain message decryption code, private keys or plaintext message storage.

### Server and Tor

The server is exposed through a v3 onion service. The app uses the exact built-in default onion unless the user explicitly chooses a custom onion. Custom onion addresses are pinned locally after first successful connection and shown with a trust warning.

No clearnet fallback, DNS dependency, analytics SDK, crash-reporting network call or third-party asset should bypass Tor.

### Spam controls

Use layered controls: per-installation-key quotas, global quotas, signed capability tokens, message/fan-out limits, and proof-of-work only when suspicious. Play Integrity may be used for the Google Play build but cannot be the only defense.

### Storage and Docker

Docker is the runtime layer, not the encryption layer. Development uses a normal named volume. Production should use a Linux encrypted host filesystem (LUKS/dm-crypt) mounted at `/srv/torchat-secure`, then expose subdirectories through Docker bind mounts:

```text
/srv/torchat-secure/
├── postgres/
├── onion/
├── backups/
└── runtime/
```

Use Docker Compose secrets for passwords and operational secrets. Never commit onion private keys, passwords or production `.env` files.

## Work completed

1. Created the repository in `D:\git\torchat`.
2. Added architecture, MVP, threat-model and deployment documents.
3. Added Rust workspace with `torchat-core` and `torchat-server`.
4. Added development Docker Compose with server and PostgreSQL.
5. Added a read-only server container with a temporary filesystem for `/tmp`.
6. Added initial endpoints:

```text
GET  /health
POST /v1/bootstrap/challenge
POST /v1/installations
POST /v1/sessions
```

7. Verified `cargo fmt`, `cargo test --workspace` and `docker compose config`.
8. Added protocol v1 documents and Rust identity core with Ed25519 signing,
   installation IDs, fingerprints, invite payloads and strict onion validation.
9. Replaced placeholder bootstrap/session proofs with signature verification;
   added authenticated, in-memory WebSocket relay delivery. Message ciphertext
   is never written to PostgreSQL.
10. Added OpenMLS as the maintained MLS boundary and a minimal Android
    Gradle/Compose project with Android Keystore and cleartext blocking.
11. Verified Rust tests, Compose config and Android debug APK build.
12. Added the Slint desktop client sharing `torchat-core`, with persistent
    identity, SOCKS transport and chat UI.
13. Fixed the server Docker build for the expanded workspace: the image now
    copies `clients` and `infra/db`, and uses Rust 1.94 required by OpenMLS.
14. Added a committed shared Android/desktop Tor client template, per-install
    runtime directory and SOCKS transport boundary.
15. Added a public OpenMLS two-member conversation API with KeyPackage,
    Welcome/ratchet-tree and application-message round-trip tests.
16. Added Android SQLCipher local message state, client-only pending queue
    model, an Android Keystore-wrapped database passphrase and a stable
    Keystore-protected identity seed.
17. Added a transitional native binding, validated QR invite format,
    Android QR display/scanning and native Android relay transport over SOCKS5.
18. Added the Android onboarding shell: splash/logo, Tor and relay status,
    server-backed nickname setup, chats/contacts tabs and authenticated
    contact-directory search by nickname. Added the profile/directory API;
    it stores only profile metadata, never message content.
19. Added the Flutter mobile client flow, Android MethodChannel/EventChannel
    bridge, canonical onion build configuration and a TorChat foreground
    service that owns Tor, relay, MLS receive processing and notifications.
20. Moved the native Android runtime into `apps/mobile`, removed Gradle's
    dependency on the old Compose tree, and added a C ABI plus Dart FFI
    wrapper for identity/MLS operations.
21. Removed the old TUI client and replaced it with a lightweight Slint
    desktop client using the same API, identity rules, relay payloads and MLS
    state as Flutter mobile.
22. Added checked-in Alice/Bob developer identities and a two-sided MLS
    fixture. A Rust integration test proves encrypted mobile/desktop messages
    decrypt in both directions and survive snapshot restore.
23. Added encrypted persistent desktop state, Android SQLCipher state,
    conversation restore, delivery receipts and local-only message history.
24. Added modern Flutter and Slint shells with splash, Tor/onion connection
    state, chats, contacts, identity, QR and message composer views.
25. Kept focused public scripts for start, stop, Android deploy and desktop
    run; helpers live under `scripts/internal`.
26. Wi-Fi ADB discovery now resolves mDNS automatically and deduplicates the
    service-name and `IP:port` representations of one physical phone.
27. Android debug APKs embed the canonical v3 onion and selected Alice/Bob
    identity at build time. Mobile and desktop reject LAN/direct relay URLs;
    relay traffic always requires Tor.
28. Android Tor initialization now treats a slow first onion circuit as
    transient and retries with bounded exponential backoff. Open chats refresh
    on incoming messages and delivery-state changes.
29. The development onion, server and PostgreSQL stack is running and healthy.
    Desktop completed a real managed-Tor/onion smoke connection as Bob.
30. Isolated the Docker server workspace from desktop UI sources, so desktop
    changes no longer invalidate the server image build cache.
31. Removed stale TUI runtime files and a 648 MB JVM crash dump left by an
    earlier Android build.
32. Added `rebuild-dev.ps1`: one command verifies Rust/Flutter, builds the
    debug APK, rebuilds images, force-recreates the Docker stack without
    deleting volumes and verifies `/health` through the public onion.
33. Fixed the Android startup stall at 50–80%. The mobile relay now performs
    the SOCKS5 domain-name handshake itself, so Android never resolves or
    connects to the v3 onion outside Tor. A single onion attempt is bounded,
    retries are visible, bootstrap progress no longer regresses from 100% to
    85%, and the latest Tor status is replayed when Flutter attaches late.
    The debug APK was installed on the physical Xiaomi over Wi-Fi ADB and
    reached the profile/WebSocket-ready state through the canonical onion.
34. Fixed the desktop 80% onion authentication failure. `run-desktop.ps1`
    detects and removes only an orphaned managed Tor tied to the desktop data
    directory, managed Tor exits automatically with its owning desktop
    process, relay authentication waits for Tor bootstrap 100%, and the Tor
    progress mapping now correctly reaches 70%. A clean headless launch
    connected Bob through the canonical onion and left no orphaned `tor.exe`.
35. Moved debug Bob/Alice MLS conversation seeding into the Android foreground
    service. The service now has the local conversation state before starting
    its receive loop, so an incoming desktop application frame can be
    decrypted even when Flutter has not opened Bob yet. Verified a real
    desktop-to-Android message: desktop reported `delivered`, Android showed
    the foreground notification `Nowa wiadomość` and kept the service alive.
36. Added the unified `scripts/torchat.ps1` entrypoint. `full-deploy` runs the
    rebuild, Docker/onion healthcheck, Wi-Fi ADB Android deployment and desktop
    launch in that order. Android deployment can skip the server when the
    orchestrator has already started it; `status` reports Docker, ADB and
    desktop state.
37. Hardened the deployment orchestration: Android deploy can reuse an
    existing APK/server, PowerShell child parameters are passed by name,
    transient onion healthcheck timeouts are retried correctly, and the shared
    `dev.env` writer now emits UTF-8 without BOM so Gradle reads the onion URL.
    A real `torchat.ps1 full-deploy` completed Rust/Flutter checks, Docker
    rebuild, onion healthcheck, Android installation and desktop launch.
38. Implemented client-side offline sending queues. Android now keeps messages
    as `PENDING` when Tor/relay is unavailable and retries them after every
    reconnect using a stable message ID. Desktop persists `pending`/`sending`
    messages, stores the already-encrypted relay payload locally, and flushes
    the queue on relay reconnect. The server remains live-only and stores no
    message data.
39. Added signed, expiring invite codes. Each invite contains a random ID,
    fifteen-minute expiry, the stable installation fingerprint, one MLS
    KeyPackage and an Ed25519 signature bound to the installation identity.
    Android validates the signature/expiry, shows the remote fingerprint for
    explicit user confirmation and records consumed invite IDs locally. Desktop
    can display a fresh QR invite and accept a pasted invite code, then creates
    the MLS conversation and sends the Welcome through Tor.

## Current limitations

- The relay is deliberately live-only. It has no envelope table and no offline
  queue; an offline recipient produces `recipient_offline`.
- PostgreSQL stores installation/directory metadata and hashed sessions only.
  Message plaintext, ciphertext, attachments and MLS state are client-local.
- Challenges, active sessions and connected WebSockets are memory-backed and
  are lost when the server restarts.
- Directory contacts expose public identity metadata but not reusable MLS
  KeyPackages. A non-development first conversation still requires QR exchange.
- Alice/Bob fixtures and private keys are public development data. They bypass
  the QR setup only in debug builds and must never be used in production.
- Wi-Fi ADB and debug APK installation currently work on the physical Xiaomi.
  Background desktop-to-Android delivery is verified; the remaining manual
  check is opening Bob in Flutter and confirming the stored message renders in
  the conversation view.
- Android foreground receive is implemented, but production-quality battery,
  OEM process-killing and reboot behavior still needs a longer device test.
- Client-side queue retry covers loss of the sender's Tor/relay connection.
  `recipient_offline` remains a live-only relay result; changing that would
  require a separate protocol/server decision.
- Invite reuse is blocked by the MLS pending-member rotation and a local
  consumed-invite registry. The current desktop UI accepts pasted invite text;
  native desktop camera/QR scanning can be added later.
- No production release signing, iOS Tor integration, abuse controls or
  independent cryptographic review has been completed.

## Development workflow

```powershell
cd D:\Git\torchat
.\scripts\torchat.ps1 full-deploy
```

Focused commands:

```powershell
.\scripts\torchat.ps1 start
.\scripts\torchat.ps1 deploy-android
.\scripts\torchat.ps1 desktop
.\scripts\torchat.ps1 status
.\scripts\torchat.ps1 stop
```

Legacy focused scripts remain available:

```powershell
.\scripts\rebuild-dev.ps1
.\scripts\start-dev.ps1
.\scripts\deploy-android.ps1 -ResetDevState
.\scripts\run-desktop.ps1
```

Automated verification:

```powershell
.\scripts\run-desktop.ps1 -SkipServer -HeadlessSmoke
.\scripts\run-desktop.ps1 -SkipServer -ResetDevState `
  -HeadlessSend "Wiadomość testowa z desktopu"
```

The second command requires the Alice Android client to be online. Stop with:

```powershell
.\scripts\stop-dev.ps1
```

Do not use `down -v` unless local development data is intentionally disposable.

## Next implementation order

1. Unlock the phone and confirm the installed client opens on the main chats
   screen instead of remaining on the Tor connection screen.
2. Keep Android Alice and desktop Bob online; verify one delivered MLS message
   in each direction and persistence after both clients restart.
3. Add relay integration/security tests, rate limits and replay protection.
4. Add production onion configuration, release signing and longer Android
   background/battery tests.
5. Arrange an independent cryptographic review before production claims.

## Handoff rule

Before every future work session, read this file and update `Updated`, `Work completed`, `Current limitations` and `Next implementation order`. Keep it synchronized with the detailed documents in `docs/`.
