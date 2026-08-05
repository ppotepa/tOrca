# `torchat-rendezvous-client`

Client-only rendezvous transport for pairing. It owns the WebSocket/SOCKS5
connection and pairing-slot request/response mapping; relay wire frames remain
in `torchat-relay-protocol`.
