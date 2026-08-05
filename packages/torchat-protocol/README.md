# `torchat-protocol`

Pure shared application wire contracts. This crate must remain independent of
SQLite, actor runtime, UI, Tor, and platform APIs. Cryptographic signing and
peer endpoint types remain in `torchat-core` until their dependencies are
separated in a later migration stage.
