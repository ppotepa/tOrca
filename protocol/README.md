# Protocol contract

This directory contains the language-neutral protocol contract shared by the Android client and server.

Planned contents:

```text
protocol/
├── README.md
├── envelope.md
├── errors.md
├── versioning.md
├── test-vectors/
└── generated/                 # ignored; generated client/server bindings
```

The server handles authentication challenges and ephemeral WebSocket routing.
It never stores message envelopes. Message encryption, conversation state and
decryption remain in `torchat-core`.
