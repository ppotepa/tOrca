# Test layout

```text
tests/
├── protocol/       # cross-language envelope and serialization vectors
├── security/       # replay, tampering, wrong-key and downgrade tests
├── integration/    # Android/client-core/server delivery tests
└── fixtures/       # synthetic data only; never real private keys
```

Security tests must run against a server that has no decryption capability.
