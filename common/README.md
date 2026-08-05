# `common/`

Shared Rust crates for TorChat. This directory owns platform-independent
protocol, cryptographic, client-domain, runtime, engine, storage, transport,
and FFI boundaries.

The relay must not gain dependencies on client storage, runtime, engine, or
peer transport. Keep platform APIs in `apps/desktop/native/` or the appropriate Flutter
platform adapter. See `docs/architecture/dependency-rules.md` before changing
crate boundaries.
