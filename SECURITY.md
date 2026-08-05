# Torca Security Policy

## Supported versions

Only the newest published Torca 0.2 test build is supported. Testers should
upgrade when a newer beta or release candidate is published. Older test builds
may be rejected when a protocol or storage issue requires a coordinated update.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue before maintainers
have had an opportunity to investigate it. Send a private report to the project
owner through the private contact channel associated with the GitHub account.
The report should include:

- affected Torca version, build number and commit;
- platform and operating-system version;
- reproducible steps or a minimal proof of concept;
- expected and observed impact;
- whether keys, message plaintext, attachments or identity data may be exposed;
- a sanitized diagnostic bundle when it is safe to provide one.

Do not include private keys, pairing codes, message plaintext, contact data or
unencrypted databases in a report.

## Response process

A report is triaged as one of:

- critical: key disclosure, remote code execution, plaintext disclosure or
  reliable identity compromise;
- high: authentication bypass, durable message integrity failure or practical
  deanonymization introduced by Torca;
- medium: local information disclosure, denial of service or security control
  bypass requiring significant preconditions;
- low: hardening opportunity without a demonstrated security boundary failure.

The maintainer will acknowledge a complete report, reproduce it when possible,
prepare a fix on a private branch when disclosure would increase risk, publish a
new signed build and disclose the issue after users have a reasonable upgrade
window.

## Security boundaries

Torca aims to protect message content and local identity material against the
pairing relay and ordinary network observers. It does not protect against:

- a compromised endpoint or operating system;
- malware with access to the user session;
- global traffic analysis;
- vulnerabilities in Tor or platform cryptographic libraries;
- disclosure by the person receiving a message;
- physical access to an unlocked device.

See `docs/security/threat-model.md` for the detailed 0.2 model.

## Release security requirements

An official test release must have:

- a version and commit recorded in the application and release report;
- signed platform artifacts;
- dependency and license policy checks;
- passing diagnostic redaction tests;
- a privacy review of release logs and exported diagnostics;
- checksums published next to distributed artifacts;
- a source tag identifying the corresponding source.
