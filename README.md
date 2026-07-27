# TorChat

Privacy-oriented Flutter chat for Android and desktop accessed exclusively
through a Tor v3 onion service.

## Architecture decision

The server is an untrusted delivery service. It authenticates sessions and stores/routes opaque protocol envelopes, but it must never possess message keys or plaintext.

The mobile clients own identity keys, device keys, ratchet state, local encrypted storage, encryption and decryption.

## Proposed stack

- Mobile UI: Flutter (Android first, iOS next), with native Tor and MLS behind a platform bridge.
- Shared security/protocol core: Rust, exposed to Flutter through a stable C ABI
  and Dart FFI; native Android background code uses the same ABI.
- Group encryption: MLS (RFC 9420) through a vetted, audited implementation; do not implement cryptography in the application layer.
- One-to-one sessions: use the same MLS machinery for two-member groups, avoiding two independent protocol implementations.
- Local storage: SQLCipher-backed SQLite, with the database key held in iOS Keychain / Android Keystore.
- Server: Rust (Axum/Tokio) or Go; initial implementation should use Rust so protocol envelope validation can share types with the client core.
- Database: PostgreSQL for installation identities, directory profiles and
  hashed sessions only. Version 0.1 does not persist messages or ciphertext.
- Live delivery: authenticated WebSocket over the onion service.
- Tor: one or more v3 onion services in front of the API; the API binds only to loopback/private networking.
- Deployment: Docker/Podman, separate database, queue and onion-service volumes; no public clearnet listener in the privacy deployment.

## Stable development workflow

```powershell
.\scripts\torchat.ps1 doctor -Environment local
.\scripts\torchat.ps1 env up -Environment local
.\scripts\torchat.ps1 build -Environment local -Target all
.\scripts\torchat.ps1 deploy -Environment local -Target android
.\scripts\torchat.ps1 status -Environment local
.\scripts\torchat.ps1 env down -Environment local
```

`local` creates a private persistent Docker stack and a stable onion per
workstation. Its generated endpoint and database password live only in
`.torchat/runtime/local/`; they are never committed. Normal deployment keeps
the app identity and encrypted local history. A destructive reset requires an
explicit `reset -Confirm` command.

Android updates are installed in place, including release APKs: they preserve
the Android Keystore identity and encrypted local database. The desktop
runtime likewise uses `.torchat/clients/desktop/identity.key` when launched
through `torchat run`; neither client should show onboarding after a normal
restart or deploy.

`staging` is a separate Linux-hosted onion service. Developer machines never
start or own that service; they build clients against the public onion from the
staging manifest.

Use `scripts/torchat.ps1` as the single command entry point. The old focused
desktop/rebuild scripts were removed:

```powershell
.\scripts\torchat.ps1 full -Environment local
```

All clients use the exact v3 onion selected by the environment manifest. The
Android relay and desktop runtime use Tor; Wi-Fi is only used by ADB to install
the APK.

`torchat.ps1 full` performs the complete local handoff: Docker rebuild, client
builds, Android deployment and Flutter Windows start. It preserves PostgreSQL,
onion volumes and client identity state.

## Non-negotiable rules

1. Never write a custom encryption protocol.
2. A password authenticates an account; it is not the message-encryption key.
3. Every device has its own key material and appears as a separate device in the security view.
4. Removing a device causes a group epoch/key update.
5. The server receives ciphertext, routing identifiers, timestamps and sizes only; metadata minimization is a separate explicit feature.

## Repository structure

```text
torchat/
├── mobile/                    # Flutter Android/iOS client
├── desktop/                   # Rust Tor/MLS runtime sidecar
├── common/torchat-core/       # shared Rust identity/protocol/security core
├── server/torchat-server/     # untrusted delivery service
├── protocol/                  # client/server contract and test vectors
├── infra/                     # Tor, database and deployment configuration
├── tests/                     # protocol, security and integration tests
└── docs/                      # architecture and threat model
```

## Current status

The Rust server, PostgreSQL, stable development onion and shared Flutter client
are implemented. The Rust sidecar owns desktop Tor/MLS/runtime state.
`cargo test --workspace`, Flutter analysis/tests/APK build,
Docker build and a real desktop managed-Tor smoke connection pass.

The development Xiaomi is deployable over Wi-Fi ADB. See [`HANDOFF.md`](HANDOFF.md)
for the current physical-device test status and remaining limitations.
