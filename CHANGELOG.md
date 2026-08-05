# Changelog

All notable user-visible and compatibility changes to Torca are documented here.
The project uses semantic versions with an additional monotonically increasing
platform build number.

## 0.2.0-beta.1

### Added

- One canonical Rust engine inbox for commands, platform lifecycle facts, peer
  events, relay events, timers, effect outcomes and shutdown.
- Granular command handlers grouped by capability, contact, conversation,
  message, pairing, peer, profile and query responsibilities.
- Durable direct-P2P message retry with delivery/read receipt state.
- Typed pairing relay effects executed outside the state-owning actor.
- Release information, sanitized local diagnostic export and destructive local
  profile reset in settings.
- Signed offline update-manifest verification using Ed25519.
- Android no-backup/no-transfer policy for application data.
- Release matrix, manual-evidence receipts, SBOM, SHA-256 checksums and signed
  update-manifest tooling.
- Image attachment source, geometry, frame-count and wire-size limits.

### Changed

- Product-facing name is Torca. Stable internal package ids, database paths and
  credential namespaces remain unchanged to preserve upgrades.
- Windows and Android use the same Rust command ordering instead of a
  Windows-specific Flutter serialization queue.
- Pairing relay is restricted to rendezvous; contact messages are delivered
  directly over authenticated onion peer links.
- Android activity responsibilities are split between lifecycle, command
  dispatch and profile reset.

### Removed

- Alternate actor loops and `legacy`, `compatibility` and implementation `V2`
  paths.
- Dead secret-migration and pairing-transport APIs.
- Debug release validation and the version-specific 0.1 release scripts.
- Deprecated settings inputs and duplicate profile-reset actions.

### Security

- Release builds require Android signing material and embed no development
  pairing identities.
- Diagnostics are local-only and exclude message bodies, attachments, private
  keys, pairing codes and capability tokens.
- Update manifests are signed and independently reverified against the public
  key embedded in the clients.
- Managed Tor reset refuses path traversal, symlink escape and deletion outside
  the Torca profile.

### Compatibility

This beta is `forward-only` once a future storage migration is introduced. For
the current beta, rollback must still be confirmed using the previous signed
candidate and a real profile before release. See
`docs/release/upgrade-and-rollback.md`.
