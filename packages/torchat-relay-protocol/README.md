# `torchat-relay-protocol`

Pure wire contracts for the ephemeral rendezvous relay. This crate contains
only opaque pairing frames and serialization constants; it has no storage,
client runtime, peer transport, UI, or actor dependencies.

The relay may restart and lose all in-memory pairing state. Existing contacts
and normal application messages do not use this protocol.
