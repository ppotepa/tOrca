# `services/torchat-relay/`

The relay is an ephemeral rendezvous service. It owns short-lived pairing
slots, connections, expiry, admission limits, and opaque rendezvous frames.

It must not persist contacts, profiles, messages, application history, or
client state, and must not depend on client storage, runtime, engine, or peer
transport. Its wire contract lives in `packages/torchat-relay-protocol`.
