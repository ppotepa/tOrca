# Relationship removal state machine

Relationship removal is a typed workflow. Message text is not a command
boundary; the legacy `torchat-relationship-removed-v1:` marker is accepted
only by the compatibility parser and only when its suffix is valid removal
JSON.

## States

```text
active -> removal_pending -> removed -> repaired
             |                 |
             +---- replay -----+
```

- `active`: the contact can exchange ordinary messages and has a live MLS
  relationship.
- `removal_pending`: a local removal request has been committed and its
  durable outbox/ack workflow may still be retried.
- `removed`: the contact is blocked, the relationship tombstone is durable,
  and ordinary queued delivery/MLS state is suppressed according to
  `preserveHistory`.
- `repaired`: a fresh pairing clears the old tombstone and creates a newer
  relationship boundary.

## Invariants

1. A normal message containing the legacy marker cannot transition the
   relationship. Only a typed application payload or a valid compatibility
   JSON payload can do so.
2. The transition and tombstone write are atomic with the local projection.
3. A replay older than the current relationship boundary is consumed without
   mutating the repaired relationship.
4. `preserveHistory=false` removes ordinary local history and technical MLS
   state; the removal system event remains available for audit/UI.
5. A fresh pairing creates a newer boundary before ordinary traffic is
   accepted again.

The compatibility path is temporary. New producers must use the typed
`requestRelationshipRemoval` command and the typed `RelationshipRemoved`
application payload.
