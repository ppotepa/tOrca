# Unified Engine Inbox

## Decision

Every `ClientEngine` instance owns one bounded `mpsc<EngineInputEnvelope>` queue. Every input capable of changing engine state must cross this queue before it is handled by `ClientEngineActor`.

The active production entry point is `ClientEngineActor::run_unified`. The older `run` implementation remains only as a compatibility reference in `actor/legacy.rs`; `ClientEngine` does not call it.

## Inputs

`EngineInputEnvelope` carries:

- `input_id` — unique identity of this processing step,
- `correlation_id` — request or operation identity,
- `causation_id` — input that caused a derived input or effect outcome,
- `source` — Client API, FFI, peer, relay, platform, scheduler or effect worker,
- enqueue timestamp,
- typed `EngineInput` payload.

The unified input variants are:

- commands,
- platform lifecycle facts,
- peer transport events,
- relay events,
- scheduler timers,
- effect outcomes,
- shutdown.

## Single-writer invariant

`ClientEngineActor` remains the only owner of mutable engine and domain state. The active actor loop receives one envelope at a time and calls `process_unified_input`.

Peer listeners, cancellation handling, timer scheduling and effect workers are ingress producers only. They must not mutate actor state.

Relay frames discovered during a poll tick become causally-linked derived `RelayEvent` envelopes. They are processed through the same dispatcher before the loop accepts the next external input.

## Scheduler

`EngineSchedulerPlan` is published through a Tokio watch channel to an external scheduler task. Timers return as `EngineInput::TimerElapsed` with a generation number. An input from an obsolete generation is ignored.

This prevents stale retry, relay-poll or peer-probe deadlines from running after a lifecycle or state transition has changed the schedule.

## Effects

Blocking rendezvous work must not execute in the state-owning actor. Pairing code refresh, pairing-code submission and remote cancellation are represented by typed relay effects and executed using `spawn_blocking`.

The concrete relay instance is temporarily owned by the worker. A placeholder remains in the actor and records lifecycle changes such as SOCKS rotation or session invalidation. These controls are replayed when the relay returns in `EngineInput::EffectOutcome`.

The outcome retains request correlation and input causation. Local runtime state and idempotent command results are committed only after the effect result returns to the actor.

Existing durable SQLite outboxes, pending Welcome records, retry deadlines and processed-command records remain the durability mechanism. This architecture does not introduce event sourcing.

## Outputs

The actor returns explicit processing results containing:

- runtime and engine events,
- effects,
- derived inputs,
- scheduler-plan changes,
- stop control.

`PendingResponseRegistry` resolves RPC responses before events enter the public event publisher. A slow or abandoned UI event consumer therefore cannot block command completion. Outstanding waiters are failed when the actor output channel closes.

## Host and UI behavior

FFI signatures and the JSON command contract remain unchanged. FFI and Client API requests receive distinct ingress source metadata.

Flutter no longer adds a Windows-only command serialization queue. Desktop and mobile rely on the same Rust engine FIFO boundary. The pairing watchdog remains a recovery mechanism for attach, reconnect and restart; normal convergence is driven by projection and invite events.

## Architectural ratchets

`packages/torchat-client-engine/tests/unified_engine_inbox.rs` verifies that:

- the active actor has one state-mutating receiver,
- timers are external and generation-fenced,
- relay frames become input envelopes before mutation,
- blocking rendezvous calls exist only in effect workers,
- public event backpressure cannot block response resolution,
- Flutter does not reintroduce a platform-specific command queue.
