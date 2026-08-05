# `packages/torchat-runtime`

Owns deterministic client-domain orchestration: state transitions, pairing
rules, retry policy, projections, and runtime effects. It must remain testable
without a database, network, WebSocket, Tor, or platform API.

Storage and transport are supplied through boundaries owned by the client
engine until their planned crate extraction is complete.
