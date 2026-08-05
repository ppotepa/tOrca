# Torca Third-Party Notices

Torca includes third-party open-source software distributed under its respective
licenses. This file is an overview and is not a replacement for the license text
shipped by each dependency.

## Release requirement

Every official binary release must include machine-generated dependency and
license reports for the exact tagged source revision:

- Rust dependency policy output from `cargo deny check`;
- a Rust SBOM generated from `Cargo.lock`;
- Flutter/Dart package inventory generated from each `pubspec.lock`;
- Android dependency inventory and license metadata;
- notices shipped by Flutter, Tor, SQLCipher/OpenSSL and other native components.

The generated reports must be published next to the release artifacts and their
checksums. A release must fail when a dependency has an unknown source or a
license outside the allow-list in `deny.toml`.

## Principal components

Torca uses or may distribute components from the following projects:

- Rust and the Rust standard library;
- Tokio and the Rust asynchronous ecosystem;
- rusqlite, SQLite, SQLCipher and OpenSSL;
- OpenMLS and supporting cryptographic crates;
- Tor and Android Tor integration libraries;
- Flutter and Dart;
- Riverpod and Flutter platform plugins;
- QR, scanner, image-processing and secure-storage libraries.

Each component remains copyrighted by its respective authors and is distributed
under the license selected by that project. Dependency lockfiles and generated
SBOMs are the authoritative inventory for a specific Torca release.

## Torca license

Original Torca source code is licensed under AGPL-3.0-or-later as described in
`LICENSE`. Third-party code is not relicensed by this notice.
