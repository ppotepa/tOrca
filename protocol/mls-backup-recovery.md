# MLS backup and recovery policy for 0.1

MLS snapshots are encrypted application state, not portable identity backups.
The database backup and the device secure-store state must be restored as one
unit.

- A restore must never replace a newer local MLS state with an older snapshot.
- If the secure-store monotonic anchor is missing, reset, or lower than the
  snapshot anchor, the conversation enters `re-pair required` recovery. The
  client must not continue encrypting with that snapshot.
- A backup restored on a new device is accepted only after identity recovery
  and a fresh relationship verification. Copying the SQLCipher file alone is
  insufficient.
- Unsupported snapshot versions and corrupt metadata fail closed. They must
  not be silently interpreted as the current format.
- Recovery errors may expose only a generic diagnostic state; snapshots,
  private keys, group secrets and full installation identifiers are excluded
  from logs and exported diagnostics.
