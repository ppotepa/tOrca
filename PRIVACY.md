# Torca Privacy Notice for Test Builds

Torca 0.2 is a test release. This document describes the intended data flow of
the software in this repository. Distributors of modified builds are
responsible for documenting any additional collection they introduce.

## Data stored on the device

Torca stores the following locally:

- installation identity and private key material;
- Tor onion-service identity material;
- MLS group and epoch state;
- contact relationships and endpoint capabilities;
- conversation and message history;
- durable delivery and retry state;
- user preferences;
- encrypted attachment cache and local diagnostic files.

Sensitive application data is intended to be stored using the platform secret
store and SQLCipher-compatible encrypted SQLite persistence. The security of
that storage still depends on the device, operating system and user account.

## Data sent to contacts

A contact may receive:

- the messages and attachments explicitly sent to that contact;
- delivery and read receipts when enabled;
- typing and presence signals when enabled;
- protocol metadata needed to authenticate and operate the direct peer link.

The recipient can retain or disclose information received from the user. Torca
cannot technically prevent that.

## Pairing relay

The relay is used only as an ephemeral rendezvous service for pairing. It may
observe connection timing, network-level metadata and opaque pairing frames. It
is not intended to receive:

- message plaintext;
- attachment plaintext;
- client private keys;
- conversation history;
- an offline message mailbox.

Pairing slots are designed to exist only in relay process memory and expire.

## Direct message delivery

After pairing, contact traffic is delivered directly through Tor onion services.
Torca does not intentionally route conversation messages through the pairing
relay.

## Diagnostics

Torca does not automatically upload diagnostics in the 0.2 test channel.
Diagnostic export is a user-initiated local operation. Exported diagnostics must
be redacted and must not contain:

- message or attachment plaintext;
- private keys or MLS state;
- SQLCipher keys;
- pairing codes;
- endpoint capability tokens;
- onion-service private keys.

Users should review a diagnostic package before sharing it.

## Telemetry

The baseline Torca 0.2 source does not include advertising, behavioural
analytics or automatic crash-report upload. A distributor must clearly disclose
any telemetry added to a modified build.

## Backups

Application databases, private keys and encrypted attachment data should be
excluded from cloud and operating-system backups unless a separately designed,
end-to-end encrypted backup feature is introduced. Testers should not assume
that reinstalling Torca can restore an identity or message history.

## Deleting local data

The local reset action is intended to remove the application profile, keys,
database, retry queues, cached attachments and preferences from the current
device. It cannot delete copies held by contacts or previously shared diagnostic
bundles.

## Limitations

Torca does not provide protection from a compromised device, malware, an
unlocked user session, global traffic analysis, Tor vulnerabilities or voluntary
disclosure by a contact.
