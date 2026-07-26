# TorChat

Privacy-oriented Flutter mobile and Slint desktop chat accessed exclusively
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

## Development commands

```powershell
.\scripts\torchat.ps1 full-deploy
.\scripts\torchat.ps1 start
.\scripts\torchat.ps1 deploy-android
.\scripts\torchat.ps1 desktop
.\scripts\torchat.ps1 status
.\scripts\torchat.ps1 stop
```

The full development deployment rebuilds the Rust/Flutter clients and Docker
stack, verifies the canonical onion, discovers Wi-Fi ADB, installs and starts
Android Alice, then launches desktop Bob in a separate window. It preserves
development volumes and uses the single endpoint from `infra/config/dev.env`.

The underlying scripts remain available for focused work:

```powershell
.\scripts\start-dev.ps1
.\scripts\start-dev.ps1 -Rebuild
.\scripts\rebuild-dev.ps1
.\scripts\deploy-android.ps1 -ResetDevState
.\scripts\run-desktop.ps1
.\scripts\stop-dev.ps1
```

All development clients read the single endpoint from
`infra/config/dev.env`. The Android relay and desktop client use Tor; Wi-Fi is
only used by ADB to install the APK.

`rebuild-dev.ps1` performs the complete clean handoff from source code to a
running environment: Rust and Flutter checks, debug APK build, Docker image
rebuild, forced container recreation and a final healthcheck through the onion
service. It preserves PostgreSQL and onion volumes. Use `-NoCache` only when
the Docker layer cache must be discarded.

## Non-negotiable rules

1. Never write a custom encryption protocol.
2. A password authenticates an account; it is not the message-encryption key.
3. Every device has its own key material and appears as a separate device in the security view.
4. Removing a device causes a group epoch/key update.
5. The server receives ciphertext, routing identifiers, timestamps and sizes only; metadata minimization is a separate explicit feature.

## Repository structure

```text
torchat/
├── apps/mobile/               # Flutter mobile client
├── crates/torchat-core/       # shared Rust identity/protocol/security core
├── server/torchat-server/     # untrusted delivery service
├── protocol/                  # client/server contract and test vectors
├── infra/                     # Tor, database and deployment configuration
├── tests/                     # protocol, security and integration tests
└── docs/                      # architecture and threat model
```

## Current status

The Rust server, PostgreSQL, stable development onion, Flutter Android client,
Slint desktop client, OpenMLS direct-chat fixture and encrypted local stores
are implemented. `cargo test --workspace`, Flutter analysis/tests/APK build,
Docker build and a real desktop managed-Tor smoke connection pass.

The development Xiaomi is deployable over Wi-Fi ADB. See [`HANDOFF.md`](HANDOFF.md)
for the current physical-device test status and remaining limitations.
