# Torca Test Release Support

Torca 0.2 is a test release. Reports are useful only when they identify the
exact build and describe a reproducible user-visible problem.

## Before reporting

1. Open **Settings → Test release and support**.
2. Tap the version row to copy product, version, build, channel and commit.
3. Reproduce the problem once more when it is safe to do so.
4. Export sanitized diagnostics from the same section.
5. Check the known issues published with the release.

Do not reset the local profile before exporting diagnostics unless the problem
itself concerns reset. Reset permanently removes local evidence and data.

## Report contents

Include:

- copied Torca release information;
- Windows or Android version and device model;
- what you expected;
- what happened;
- exact steps and approximate UTC time;
- whether Tor, network, background mode, restart or upgrade was involved;
- whether either peer was offline;
- whether the problem reproduced;
- sanitized diagnostic export when available.

For message delivery issues, include message direction and UI status, but do not
paste the message body. For pairing issues, describe the state shown on both
devices, but never include the pairing code.

## Sensitive information

Never attach or paste:

- plaintext messages or private attachments;
- pairing codes or QR contents;
- SQLCipher database keys;
- identity or onion-service private keys;
- MLS state;
- capability tokens;
- unencrypted profile directories;
- Android keystores, Windows credentials or update-signing keys.

Use the Security Policy for suspected vulnerabilities. Do not publish security
reports in a public issue.
