# TorChat Agent Instructions

## Mission

TorChat is a privacy-oriented Flutter chat client for Android and desktop. All
relay traffic uses Tor v3 onion services. The server is an untrusted live-only
delivery service and must never persist message bodies, ciphertexts, envelopes,
MLS state, keys, or chat history.

The current refactor has one strict architectural goal: remove active legacy
paths. Business rules must have one implementation in
`common/torchat-client-runtime`.

## Architecture Boundaries

- `common/torchat-client-runtime` owns client lifecycle rules, canonical DTOs,
  request/response dispatch, storage-facing state changes, and runtime events.
- `common/torchat-core` owns crypto, identity, wire payloads, protocol
  validation, and MLS primitives. It does not own client lifecycle rules.
- `desktop` owns Tor, transport, process lifecycle, platform MLS operations,
  SQLite adapter code, JSON Lines stdio, and forwarding runtime events.
- `mobile/android` owns Tor, relay transport, foreground-service lifecycle,
  platform MLS operations, SQLCipher persistence, and MethodChannel/EventChannel
  forwarding.
- `mobile/lib` is the only UI layer. Flutter consumes typed runtime models and
  does not implement pairing, contact, conversation, or message transitions.
- `server/torchat-server` remains live-only. Do not add server-side message or
  ciphertext storage.

The current refactor source of truth is `REFACTO1.MD`. The implementation must
create the generated engine contract described there and keep Android, desktop,
Flutter, and Rust request names and state values aligned with that contract.

## Runtime Ownership

The shared runtime is the only owner of:

- pairing accept, reject, cancel, archive, expiry, completion, deduplication,
  inbox/outbox merge, and terminal-state handling;
- contact creation, update, verification state, nickname fallback,
  fingerprint/public-key mapping, and duplicate handling;
- conversation creation/open/close, active/offline/pending/failed mapping,
  previews, `lastMessageAt`, unread counters, and read reset;
- message creation, queueing, sending state, delivery state, retries, incoming
  persistence decisions, receipts, and unread updates;
- canonical `RuntimeEvent` creation and the runtime event queue.

Platform code may persist the result of a runtime decision and may persist
technical MLS/ciphertext snapshots. Platform code must not decide the business
transition before writing that result.

Do not add local copies of runtime lifecycle methods in Kotlin, desktop
adapters, or Flutter. Do not create synthetic runtime events outside the shared
runtime.

## Legacy-Path Policy

Legacy means an active duplicate behavior, not merely an old filename. Before
adding code, search for existing implementations and remove or route them
through the shared runtime. Do not restore old TUI, Slint, browser, Compose,
direct Dart FFI, or platform-specific lifecycle paths.

A storage call such as `putMessage`, `putContact`, or `putConversation` is valid
when it implements `RuntimeStorage` or persists a technical snapshot. It is a
legacy path when the adapter independently derives lifecycle state, unread
state, deduplication, or contact/conversation existence.

## Working Method

1. Preserve unrelated existing work in the dirty worktree. Never use
   `git reset --hard`, `git checkout --`, broad deletion, or mass cleanup.
2. For structural questions, start with the installed CodeGraph commands
   (`codegraph query`, `codegraph callers`, `codegraph callees`,
   `codegraph impact`, `codegraph files`). Use `rg` for exact symbol and
   legacy-reference searches. Use `codegraph explore` only after upgrading to
   a CodeGraph version that provides that command.
3. Read only the relevant symbols or small file sections. Do not dump whole
   generated files, databases, logs, `target/`, build directories, or
   `concat.txt` into context.
4. Use `apply_patch` for manual edits. Keep changes narrowly scoped and ASCII
   by default.
5. Run one targeted compile/check after a relevant change. Do not repeatedly
   run the full workspace, Android, and Flutter suites after every edit.
6. Before completion, run the smallest checks that still prove the changed
   boundary: Rust runtime/desktop compile for shared runtime changes, Android
   Kotlin compile for native bridge/service changes, Flutter analyze for UI or
   bridge changes, and targeted unit tests for moved business rules.
7. Report unverified areas honestly. Compilation alone does not prove that
   legacy business logic is gone.

## Token-Efficient Commands

Prefer RTK wrappers for long command output:

```powershell
rtk git status
rtk git diff
rtk git log -n 10
rtk cargo check -p torchat-client-runtime -p torchat-desktop
rtk test cargo test -p torchat-client-runtime
codegraph status .
```

Use direct commands when a wrapper does not support the operation or when the
exact output is required. Do not repeat a successful command without a code or
environment change. When RTK reports a failure and provides a tee log, inspect
that log instead of rerunning the same command immediately.

## CodeGraph

The repository-local graph lives in `.codegraph/` and is not committed. Run
`codegraph sync` after edits when the freshness banner says the graph is stale.
The installed CodeGraph CLI currently exposes these useful queries:

```powershell
codegraph query "ClientRuntime"
codegraph query "acceptPairing"
codegraph callers accept_pairing
codegraph callees dispatch_request
codegraph impact ClientRuntime
```

After upgrading CodeGraph to a release that provides `explore`, it may be used
for multi-symbol flow questions. Trust a fresh CodeGraph result for structural
questions. Use `rg` to prove that legacy names and paths no longer exist.

## Focused Verification

Use the smallest relevant check:

```powershell
cargo check -p torchat-client-runtime -p torchat-desktop
mobile\android\gradlew.bat :app:compileDebugKotlin
flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart
cargo test -p torchat-client-runtime <specific_test_name>
```

The old broad internal readiness/check scripts were removed. Do not recreate
them unless the user explicitly asks for release gates. Full test suites and
E2E are reserved for the final audit or for diagnosing a specific failure. Do
not enable RTK telemetry for this project.

## Public Development Commands

Use `scripts/torchat.ps1` as the single public entry point:

- `start-dev`
- `stop-dev`
- `status`
- `build-clients`
- `deploy-mobile`
- `run-desktop`
- `full-deploy`
- `redeploy`
- `logs`
- `test`
- `reset-client-state`

`full-deploy` preserves the local Docker/Tor stack by default and can preserve
or clean client state. `redeploy` is intentionally destructive for local
debugging: it removes local Docker volumes, generates a fresh Tor onion, builds
Android and desktop after that onion exists, deploys Android, and starts
desktop. `logs` collects Docker, Android logcat, desktop runtime, and process
diagnostics under `.torchat/logs/`.

Do not document or add new public aliases for removed legacy scripts.
