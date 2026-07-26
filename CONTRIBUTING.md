# Contributing

## Rules

- Never implement cryptographic primitives or a new message protocol in application code.
- Keep private keys inside the platform keystore or Rust core; do not expose raw key material to UI code.
- Every protocol change needs a document, test vectors and compatibility notes.
- New logging requires a privacy review.
- Tests must cover malformed, replayed, reordered and oversized input.

## Local checks

```text
cargo fmt --all -- --check
cargo test --workspace
```

Android checks will be added once the Gradle application skeleton is introduced.
