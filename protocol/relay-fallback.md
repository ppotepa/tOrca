# Relay fallback 0.1

Relay fallback in release 0.1 is live-only. The relay forwards an encrypted
envelope to a currently connected recipient and does not persist ciphertext
for later delivery.

Transport outcomes therefore have these meanings:

- `FORWARDED` means the relay accepted the live handoff and maps to `SENT`.
- `RECIPIENT_OFFLINE` means no live handoff occurred and maps to `QUEUED`.
- A later P2P or relay retry may advance `QUEUED` to `SENT` or `DELIVERED`.

The relay must not be described as offline delivery in UI, diagnostics, or
operator documentation. Durable delivery belongs to the client outbox and
peer transport, not to the relay control plane.
