# Torca 0.2 Threat Model

## Scope

This model covers the official Windows and Android Torca 0.2 test clients, the
shared Rust engine/runtime, local encrypted persistence, direct peer transport
through Tor onion services and the ephemeral pairing relay.

It does not claim protection against a compromised endpoint, malicious operating
system, global passive adversary or vulnerabilities in Tor itself.

## Assets

Primary assets:

- installation identity private keys;
- onion-service private keys;
- MLS secrets, epochs and group state;
- message and attachment plaintext;
- contact relationships and conversation history;
- endpoint capability tokens;
- pairing offers, responses and short-lived codes;
- encrypted database and attachment-cache keys.

Secondary assets:

- contact nicknames;
- presence, typing and read state;
- delivery timing;
- local filesystem paths and diagnostic metadata;
- application version and platform information.

## Trust boundaries

### Endpoint

The endpoint owns all long-term secrets and plaintext. Flutter is a presentation
and command layer. The Rust engine is the single state-transition owner. The
runtime owns domain rules. Storage owns SQL and transactions.

### Platform secret storage

The platform secret store is trusted to protect database and identity secrets
against ordinary application-level access. It is not trusted against a
compromised OS, administrator-level malware or an unlocked user session.

### Tor

Tor provides transport and onion-service reachability. Torca assumes the local
Tor process follows its protocol and keeps onion-service key material local.
Torca does not assume that Tor prevents global traffic correlation.

### Pairing relay

The relay is untrusted. It may be unavailable, malicious, curious or restarted
at any time. It must not be able to decrypt conversation messages or derive
long-term client private keys. It is allowed to observe timing, connection-level
metadata and opaque pairing frame sizes.

### Contact

A paired contact is authenticated for the relationship but is not trusted to
protect information intentionally sent to them. A malicious contact may send
invalid frames, replay data, withhold acknowledgements, exhaust retry paths or
retain disclosed content.

## Security goals

Torca 0.2 aims to provide:

- confidentiality and integrity of message content in transit;
- authenticated peer relationships established through explicit pairing;
- local encrypted persistence;
- durable, idempotent processing across retries and restarts;
- no plaintext message mailbox at the pairing relay;
- bounded parsing and transport inputs;
- redacted diagnostics;
- deterministic removal of local secret material during reset;
- explicit user-visible failure instead of silent data loss.

## Adversaries

### Network observer

Can observe that a device uses Tor and may correlate timing or volume. Should not
recover message plaintext from Torca frames.

### Malicious pairing relay

Can drop, delay, replay or reorder pairing frames and provide inconsistent
responses. Must not establish a trusted contact without the endpoint completing
the authenticated pairing flow.

### Malicious contact

Can send malformed, duplicate, stale or oversized frames and manipulate network
availability. The client must authenticate capabilities, validate protocol
versions, bound resource use and process duplicate durable operations
idempotently.

### Local non-privileged process

May inspect ordinary logs and accessible files. It should not find plaintext
message bodies, private keys or unencrypted databases in logs, temporary files
or exported diagnostics.

### Compromised endpoint

Out of scope. A process with sufficient access to memory, secret storage or the
user session can recover plaintext and keys.

## Principal threats and mitigations

| Threat | Required mitigation for 0.2 |
|---|---|
| Pairing replay or duplicate submission | Expiring codes, operation identity, idempotent processed-command records and duplicate-contact prevention |
| Relay substitution | Authenticated pairing transcript and explicit endpoint commit after effect outcome |
| Message replay | Stable message identity, authenticated protocol frames and idempotent persistence |
| Lost acknowledgement | Durable outbox, retry scheduling and duplicate-safe receiver commit |
| Stale scheduler event | Scheduler generation fencing |
| UI backpressure blocking RPC | Resolve pending response before public event publication |
| Oversized frame or attachment | Strict encoded-size, decoded-size, dimension and memory limits |
| Secret leakage through logs | Structured redaction, deny-list tests and no raw payload logging |
| Cloud backup of keys | Platform backup exclusion rules and release validation |
| Database migration failure | Transactional migration, preflight validation and fail-closed recovery path |
| Local reset leaving secrets | Coordinated engine shutdown followed by deletion of database, secret-store entries, onion keys, cache and preferences |
| Worker panic losing relay state | Catch unwind, return relay ownership and produce an explicit effect failure |
| Unbounded reconnect/retry | Bounded queues, capped exponential backoff and persisted retry deadlines |

## Release verification

A candidate release must demonstrate:

- signed release artifacts built from the tagged commit;
- dependency and license policy checks;
- pairing stress in both directions;
- exactly-once message behaviour around crash and acknowledgement boundaries;
- migration from the previous distributed build;
- Android background/recovery tests;
- Windows tray/single-instance tests;
- diagnostic privacy scan;
- eight-hour platform soak without crash or unbounded resource growth.

## Explicit non-goals for 0.2

- protection from a compromised device;
- protection from global traffic analysis;
- multi-device identity synchronization;
- server-side message availability;
- account recovery or cloud backup;
- deniable messaging;
- metadata-free presence or typing indicators.
