# Relay multi-instance routing contract

Release 0.1 runs one replica by default. The shared lease and routing
contract below define the safe boundary for a future multi-instance rollout.

## Ownership

- `connection_leases` is keyed by pseudonymous `installation_id`.
- A lease records `instance_id`, `connection_id`, and an absolute `expires_at`.
- A route producer may publish only while it owns the unexpired lease.
- A stale connection may not delete or replace a newer `(instance_id,
  connection_id)` pair.

## Shared stream record

Each cross-instance route record contains:

```text
route_id       UUID (globally unique)
installation   pseudonymous target key
instance_id    UUID
connection_id  UUID
payload        encrypted relay frame
created_at     monotonic server timestamp
expires_at     created_at + bounded TTL
```

Consumers claim records atomically and acknowledge by `route_id`. A duplicate
claim or delivery is harmless because `route_id` is deduplicated at the target
connection. Expired records are dropped; the stream never becomes an offline
ciphertext store. `RECIPIENT_OFFLINE` remains a live-only result.

## Rollout gate

The current deployment keeps `replicas=1`. Enabling more replicas requires a
shared stream implementation (PostgreSQL `SKIP LOCKED`, Redis Streams, or an
equivalent durable broker), a two-instance split test, and lease metrics for
acquire/reject/expire/claim/duplicate.
