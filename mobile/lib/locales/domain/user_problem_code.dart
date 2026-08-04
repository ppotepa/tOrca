enum UserProblemCode {
  pairingWelcomeStale('pairing_welcome_stale'),
  pairingCodeInvalid('pairing_code_invalid'),
  pairingRequiresRelay('pairing_requires_relay'),
  nicknameRequired('nickname_required'),
  inviteCodeUnavailable('invite_code_unavailable'),
  pairingGatewayUnavailable('pairing_gateway_unavailable'),
  secureConnectionPending('secure_connection_pending'),
  connectionUnavailable('connection_unavailable'),
  operationFailed('operation_failed');

  const UserProblemCode(this.wireValue);
  final String wireValue;
}
