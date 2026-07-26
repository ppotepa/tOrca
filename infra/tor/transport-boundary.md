# Tor transport boundary

TorChat application requests must use a Tor SOCKS5 client and the exact
configured v3 onion hostname. The API layer must not create a normal HTTP
client or resolve the hostname through DNS.

The Android boundary is `TorTransport`. It accepts only a 56-character
base32 v3 hostname ending in `.onion`; a custom hostname is stored locally
after the first successful connection and any later change requires explicit
confirmation. This 0.1 scaffold intentionally has no clearnet fallback.
