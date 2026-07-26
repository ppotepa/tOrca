# Envelope v1

All JSON requests use protocol version `1`. Binary fields are URL-safe base64
without padding. The server treats `ciphertext` as opaque bytes.

Registration signs the exact challenge bytes returned by
`POST /v1/bootstrap/challenge`. Session creation signs
`session-v1:<installation_id>:<challenge>`.

The live WebSocket envelope is:

```json
{"type":"envelope","version":1,"message_id":"uuid","sender":"installation-id","recipient":"installation-id","ciphertext":"base64"}
```

The server forwards this only to an active recipient connection. It does not
persist it. Offline delivery is represented by `recipient_offline` and is
retried from the sender's local queue.

The server validates routing fields and uniqueness, but never parses or
decrypts `ciphertext`.
