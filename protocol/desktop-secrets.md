# Desktop secret storage boundary

The first database-key migration supports the desktop targets currently built
by this repository: Windows and Linux. It uses `DesktopSecretStore` with an
atomic 32-byte key file and restrictive filesystem permissions (`0600` on
Unix; the Windows profile directory must be ACL-protected by the installer).
The database key is independent from the identity private key and is rotated
through the rekey journal before the new key is committed.

macOS is intentionally outside the supported migration target until a
Keychain-backed `DesktopSecretStore` is available. A future Windows backend
may replace the file store with DPAPI/Credential Manager, and the Linux backend
may replace it with Secret Service/KWallet, without changing the runtime
migration contract.

No secret, database key, identity private key, or plaintext key material may be
written to logs, diagnostics, crash reports, or provenance artifacts.
