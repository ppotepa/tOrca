# Torca Client Engine C ABI

## Version

The exported `torca_engine_abi_version()` function returns `TORCA_ENGINE_ABI_VERSION`.
Hosts must compare this value before creating an engine handle. A mismatch is a hard startup error.

## Handle ownership

- A successful create operation transfers one opaque handle to the caller.
- The handle is owned by exactly one platform host.
- Shutdown is idempotent at the host boundary, but a handle must be freed only once.
- Commands submitted after shutdown are rejected.
- A handle must not be dereferenced after its final free operation.

## Strings and buffers

- Input pointers are borrowed only for the duration of the call.
- Returned C strings are allocated by Rust and must be released by the matching Torca free function.
- Callers must not use another allocator to free Rust-owned memory.
- Null pointers are accepted only where the individual function explicitly documents them as optional.

## Threading

- The engine runtime owns its worker threads.
- Command submission and event polling may be called concurrently only through synchronized handle operations.
- Thread-local last-error storage is valid only on the thread that observed the failing call.
- Platform callbacks must return before engine shutdown can complete.

## Panic containment

Every exported operation must contain Rust panics at the ABI boundary and return `FfiStatus::PanicContained`. No unwind may cross into Kotlin, Dart, C, or C++.

## Shutdown order

1. Stop accepting platform intents.
2. Cancel event polling.
3. Submit engine shutdown.
4. Wait for the engine actor to stop.
5. Release callback resources.
6. Free the opaque handle.
7. Release any remaining Rust-owned strings.

## Status codes

The stable status values are defined by `FfiStatus` in `packages/torchat-client-engine-ffi/src/abi.rs`. New values may be appended, but existing numeric values must not change within ABI version 1.
