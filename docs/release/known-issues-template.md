# Torca <VERSION> Known Issues

Release commit: `<COMMIT>`  
Build: `<BUILD>`  
Channel: `<CHANNEL>`  
Published: `<UTC_TIMESTAMP>`

## Blocking issues

None. A release must not be distributed while this section contains an open
item involving data loss, identity reset, key disclosure, silent message loss,
duplicate contacts or permanently stuck pairing.

## Known limitations

For each limitation record:

- platforms and operating-system versions;
- user-visible symptoms;
- reliable reproduction steps;
- whether local data or message delivery is at risk;
- safe workaround;
- planned fix version;
- issue or evidence reference.

### `<ISSUE_ID>` — `<TITLE>`

- **Platforms:**
- **Impact:**
- **Reproduction:**
- **Workaround:**
- **Data risk:** none / temporary unavailability / possible loss
- **Status:** investigating / fix planned / accepted limitation
- **Reference:**

## Expected test-release behaviour

- Tor bootstrap and direct peer reachability may take longer than ordinary
  internet messaging applications.
- The pairing relay has no offline mailbox; both devices must participate in the
  pairing window.
- Android background restrictions can delay availability and are reported in
  the application.
- Torca 0.2 does not provide groups, calls, multi-device synchronization, public
  discovery or cloud backup.
- Update checking verifies a signed manifest selected by the tester; it does not
  automatically download or install software.

## Reporting

Reports must include the copied release information from settings, platform and
OS version, reproduction steps and a sanitized diagnostic export. Do not send
private keys, pairing codes, plaintext messages, attachments or unencrypted
databases.
