# `apps/desktop/native/`

This is the native desktop host, not the complete desktop application. It owns
process startup, Tor runtime, identity and secret storage, single-instance
locking, and the native bridge to the client engine.

The desktop Flutter runner and its platform adapters are owned by
`apps/desktop/flutter`. Shared presentation primitives belong to
`packages/torchat-flutter-ui`; this native host must not own Flutter views.
