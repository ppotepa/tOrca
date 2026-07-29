# Transport strategy extraction

TorChat must treat message delivery as a configurable transport concern. The
application UI, contacts, invitations, conversations, local queue and identity
model must not depend on whether a message is delivered through the current
onion relay or directly to another device.

## Current strategy: `relay_onion`

`relay_onion` is the only implemented strategy for the current release.

1. Each client runs or connects to its local Tor runtime.
2. Client API traffic goes through that runtime to one configured v3 onion
   service.
3. The onion service provides the existing relay/directory delivery path.
4. The client keeps its own durable local state: identity, contacts,
   invitations, conversations and the outbound queue.
5. The UI reports transport state (`connecting`, `connected`, `degraded`,
   `offline`) but does not contain relay-specific behaviour.

The configured onion URL is a deployment value, not a hard-coded UI value. All
clients in an environment use the same release/dev onion endpoint. Android and
desktop package this endpoint from the selected environment configuration.

## Future strategy: `p2p_onion`

`p2p_onion` is reserved for a later direct-delivery implementation.

1. Every device owns a long-lived v3 onion address and exposes a small local
   Tor-backed service.
2. A verified contact contains the peer's current reachable address and public
   identity material.
3. The sending client connects over its own local Tor runtime directly to that
   peer onion service.
4. If the recipient is offline, the sender retains the encrypted outbound item
   locally and retries when its transport becomes available.
5. A directory may still be used for discovery, invitation exchange and
   reachability metadata, but it is not a message store.

This mode brings stronger directness but costs more on mobile: background
execution, battery, long Tor bootstrap times, NAT-free onion hosting,
multi-device routing and offline delivery all need explicit product decisions.
It must therefore be introduced behind the same transport interface, not as a
second set of screens or conversation logic.

## Stable transport contract

The common client layer should expose one transport contract regardless of
strategy:

```text
start() / stop()
connectionState()
send(outboundEnvelope)
receive() -> inboundEnvelope stream
retryPending()
capabilities()
```

The contract owns routing and retryability. The local queue owns items until a
delivery acknowledgement permits their removal. Conversation UI only creates
and observes local message state; it never chooses an onion URL.

Suggested common types:

```text
TransportStrategy = relay_onion | p2p_onion
ConnectionState   = connecting | connected | degraded | offline | failed
TransportCapability = directDelivery | offlineRelay | peerHosting
```

## Configuration

Use a single explicit selection per environment:

```dotenv
TORCHAT_TRANSPORT_STRATEGY=relay_onion
TORCHAT_ONION_URL=http://<v3-onion>.onion
```

Rules:

- `relay_onion` requires `TORCHAT_ONION_URL`.
- `p2p_onion` is not selectable until its implementation and migration are
  complete; configuration parsing should fail clearly rather than silently
  falling back.
- Secrets, identities and per-device onion keys stay in local protected
  storage, never in committed environment files.
- The active strategy is injected into Android and desktop builds from the
  same environment source so a packaged client cannot accidentally use a
  different endpoint.

## Migration path

1. Extract the existing relay code behind the common transport contract.
2. Keep `relay_onion` as the default and preserve its existing wire/API
   behaviour.
3. Add configuration parsing and a visible, strategy-agnostic status model.
4. Define peer address, reachability and acknowledgement protocol fields.
5. Implement `p2p_onion` as a second adapter with feature-gated rollout.
6. Allow per-environment selection only after both adapters have end-to-end
   migration and recovery behaviour.

The initial configuration switch is an architectural boundary, not a promise
that peer-to-peer transport already exists.
