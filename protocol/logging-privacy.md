# Logging privacy and retention

Server and relay logs are operational diagnostics, not an event store.

- IDs in pairing, WebSocket, relay and queue messages must be stable
  pseudonymous digests derived from the pairing secret. Plain installation,
  sender, recipient and message IDs are not permitted in structured logs.
- Default retention is 7 days for server/relay logs and 24 hours for verbose
  debug logs. Operators may extend retention only for an incident and must
  record the incident identifier and expiry time.
- Access is limited to the service operator and the incident responder named
  for the deployment. Log exports are opt-in and must use the existing
  diagnostic sanitization path; raw database, keys, pairing secrets and
  ciphertext are never included.
- `RUST_LOG=info` is the production baseline. Debug/trace logging is temporary
  and must be disabled after the incident window.
- A separate secure-debug channel is intentionally not enabled in release 0.1:
  current diagnostics are sufficient without plaintext identifiers or payloads.
  Any future opt-in debug bundle must use the same pseudonymization, a bounded
  24-hour retention window, explicit operator action, and secure export storage.
- Deletion at the retention boundary must cover rotated files and exported
  bundles, not only the active log file.
