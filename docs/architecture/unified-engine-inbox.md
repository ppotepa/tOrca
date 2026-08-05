# Engine Inbox

## Decision

Every `ClientEngine` instance owns one bounded `mpsc<EngineInputEnvelope>` queue.
Every input capable of changing engine state must cross this queue before it is
handled by `ClientEngineActor`.

The single production entry point is `ClientEngineActor::run` in
`actor/run.rs`. Actor state and construction live in `actor/state.rs`. There is
no second actor loop, legacy implementation or platform-specific command queue.

## Inputs

`EngineInputEnvelope` carries:

- `input_id` — identity of the processing step;
- `correlation_id` — request or operation identity;
- `causation_id` — input that caused a derived input or effect outcome;
- `source` — Client API, FFI, peer, relay, platform, scheduler or effect worker;
- enqueue timestamp;
- typed `EngineInput` payload.

The input variants are:

- commands;
- platform lifecycle facts;
- peer transport events;
- relay events;
- scheduler timers;
- effect outcomes;
- shutdown.

## Single-writer invariant

`ClientEngineActor` is the only owner of mutable engine and domain state. The
actor loop receives one envelope at a time and calls `process_input`.

Peer listeners, cancellation handling, timer scheduling and effect workers are
ingress producers only. They must not mutate actor state.

Relay frames discovered during a poll tick become causally linked derived
`RelayEvent` envelopes. They are processed through the same dispatcher before
the loop accepts the next external input.

## Commands

The public command contract lives in `src/contract`. `actor/command_dispatch.rs`
contains only variant routing. Each use case has a dedicated module below
`actor/commands`. Common idempotency, response creation and effect-outcome
processing live in `actor/command_pipeline`.

Command handlers must not publish RPC responses, execute blocking I/O or mutate
the public event queue directly.

## Scheduler

`EngineSchedulerPlan` is published through a Tokio watch channel to an external
scheduler task. Timers return as `EngineInput::TimerElapsed` with a generation
number. Inputs from obsolete generations are ignored.

This prevents stale retry, relay-poll or peer-probe deadlines from running after
a lifecycle or state transition has changed the schedule.

## Effects

Blocking rendezvous work must not execute in the state-owning actor. Pairing
code refresh, pairing-code submission and remote cancellation are represented
by typed relay effects and executed with `spawn_blocking`.

The concrete relay instance is temporarily owned by the worker. A placeholder
remains in the actor and records lifecycle changes such as SOCKS rotation or
session invalidation. These controls are replayed when the relay returns through
`EngineInput::EffectOutcome`.

The outcome retains request correlation and input causation. Local runtime state
and idempotent command results are committed only after the effect result returns
to the actor.

Existing durable SQLite outboxes, pending Welcome records, retry deadlines and
processed-command records remain the durability mechanism. The architecture does
not introduce event sourcing.

## Outputs

The actor returns explicit processing results containing:

- runtime and engine events;
- effects;
- derived inputs;
- scheduler-plan changes;
- stop control.

`PendingResponseRegistry` resolves RPC responses before events enter the public
event publisher. A slow or abandoned UI event consumer therefore cannot block
command completion. Outstanding waiters fail when the actor output channel
closes.

## Host and UI behaviour

FFI signatures and the JSON command contract remain shared by Windows and
Android. FFI and Client API requests receive distinct ingress source metadata.

Flutter relies on the Rust engine FIFO boundary and does not implement another
messaging, pairing or probing state machine. Pairing reconciliation in Flutter
is limited to recovery after attach, reconnect or restart; normal convergence is
driven by projection and invite events.

## Architectural ratchets

`packages/torchat-client-engine/tests/unified_engine_inbox.rs` verifies that:

- the actor has one state-mutating receiver and one canonical loop;
- transitional and legacy source files do not exist;
- command routing delegates to granular handlers;
- timers are external and generation-fenced;
- relay frames become input envelopes before mutation;
- blocking rendezvous calls exist only in effect workers;
- public event backpressure cannot block response resolution;
- Flutter does not reintroduce a platform-specific command queue.
