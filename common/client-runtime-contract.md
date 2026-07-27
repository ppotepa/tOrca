# Flutter client runtime contract

The Flutter application is the only UI. On Android the contract is backed by
the foreground service MethodChannel; on desktop it is backed by the Rust
sidecar (`torchat-desktop --stdio-runtime`).

Both adapters expose the same methods (`connect`, `identity`, `setNickname`,
`contacts`, `contactRequests`, `conversations`, `messages`, invite actions and
`sendMessage`). Desktop transport is JSON Lines: every request is one JSON
object with `id`, `method` and optional `params`; responses contain the same
`id`, `ok` and `result` or `error`. Unsolicited events contain `type`, notably
`runtime_ready`, `tor_status`, `profile_ready` and `runtime_error`.

The server never receives message bodies or MLS state. Identity, conversation
state and the encrypted outbox stay in the client-local store.
