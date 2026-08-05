# Torca Upgrade and Rollback Policy

## Principles

- A release upgrade must preserve installation identity, contacts, messages,
  durable queues, MLS state, attachment-cache metadata and user preferences.
- Storage migration must fail closed. Torca must not silently create a new
  profile when an existing encrypted database cannot be opened or migrated.
- Database and protocol compatibility are separate. A client may understand the
  local database while still requiring a coordinated peer upgrade.
- A rollback is permitted only when the older client can safely open every local
  format written by the newer client.

## Before changing persistent formats

Every migration must define:

- source and target schema versions;
- preconditions;
- transactional steps;
- validation after migration;
- behaviour when disk space is insufficient;
- behaviour after process termination at each write boundary;
- whether the previous distributed client can still open the result;
- recovery instructions when migration cannot complete.

Migrations must remain parameterized SQL files and execute through the storage
migration boundary. Application, actor and UI code must not run ad hoc schema
changes.

## Upgrade process

1. Start from a real profile created by the previous distributed build.
2. Create an offline copy of the encrypted database, secret-store entries and
   managed Tor directory for test purposes.
3. Install the candidate over the previous build without clearing platform data.
4. Start Torca and allow migration to finish without user interaction.
5. Verify the same installation identity and contact fingerprints.
6. Verify contacts, conversations, message history, attachment metadata,
   pending delivery and processed-command records.
7. Send and receive new messages in both directions.
8. Restart both the application and operating system.
9. Repeat with the process terminated during migration and during first
   post-migration startup.
10. Record the result in `upgrade-from-previous-beta` manual evidence.

The Android test must use the same application id and signing certificate. The
Windows installer must preserve the established profile location and native
secret-store namespace.

## Failure behaviour

When migration or secret loading fails, Torca must:

- keep the original files intact whenever no transaction committed;
- display a recoverable, explicit local-storage error;
- avoid creating a second identity;
- avoid deleting or replacing the encrypted database;
- avoid retry loops that repeatedly modify the same files;
- offer sanitized diagnostics;
- require an explicit reset confirmation before any destructive recovery.

## Rollback classes

### Safe rollback

Allowed only when the newer build made no irreversible storage or secret-store
change. The previous signed artifact may be reinstalled over the current build,
and the profile must pass the same migration-preservation test.

### Data-preserving forward fix

Preferred when the newer build wrote a format the previous build cannot read.
Withdraw the faulty update manifest and publish a higher build that repairs the
problem without asking users to downgrade.

### Profile reset

Last resort for test builds when no safe repair exists. Reset destroys the local
identity, contacts, history, keys, queues, cache and managed Tor data. It must
never be initiated automatically. The user must complete the two-stage
confirmation in settings.

## Release manifest response

When a blocker is found:

- stop distributing the affected artifacts;
- remove or replace the public update manifest;
- mark a mandatory fixed update only after the fix passes the full matrix;
- never point the manifest to an artifact with a reused version/build;
- retain the withdrawn artifact hashes for incident analysis;
- notify testers with the affected version, impact and required action.

## Compatibility declaration

Release notes must state one of:

- `rollback-compatible`: the previous distributed build can safely reopen the
  profile;
- `forward-only`: users must install a newer build instead of downgrading;
- `profile-reset-required`: test data cannot be recovered and manual reset is
  required.

No release may leave rollback behaviour unspecified.
