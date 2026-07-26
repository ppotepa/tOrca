# TorChat threat model

## Protected against

- A delivery server reading message contents.
- A network observer linking the app directly to the user's IP through the Tor connection.
- Database theft revealing message plaintext, assuming device keys and local database keys remain protected.
- Later compromise of a device exposing all historical messages, when the MLS implementation and key-update policy provide forward secrecy.

## Not automatically protected against

- A compromised or rooted phone.
- Malware, screenshots, clipboard capture or a malicious keyboard.
- A user sharing their recovery secret or approving a hostile device.
- Traffic analysis, timing, message sizes, account existence and some group metadata.
- Push providers seeing notification timing or device tokens.
- A malicious server delaying, dropping or reordering messages.

## Security acceptance criteria

- No private key leaves the device in plaintext.
- Every incoming credential is signature- and account-validated before use.
- Fingerprint changes are visible, auditable and require an explicit user decision.
- Removing a device rotates the conversation epoch.
- All ciphertexts are authenticated; tampered messages are rejected.
- Server logs exclude message bodies, authorization tokens and client IP addresses where the deployment permits.
- Independent review is required before calling the product secure.
