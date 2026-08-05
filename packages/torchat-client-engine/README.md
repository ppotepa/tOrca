# `torchat-client-engine`

Owns the current client composition boundary: actor scheduling, peer transport,
rendezvous client, SQLCipher-backed storage, and the engine API consumed by the
FFI crate and desktop host.

New SQL belongs under `sql/` and must be registered through the SQLite SQL
catalog. Structural extraction must preserve the public engine and FFI
contracts.
