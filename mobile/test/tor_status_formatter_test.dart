import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';

void main() {
  test('tor status helper maps phases, labels and tone consistently', () {
    expect(TransportPhase.fromValue('connecting'), TransportPhase.connecting);
    expect(TransportPhase.fromValue('ready'), TransportPhase.connected);
    expect(
      TransportPhase.fromValue('bootstrapping').label,
      'Uruchamianie obwodu Tor',
    );
    expect(TransportPhase.connected.isConnected, isTrue);
    expect(TransportPhase.degraded.isWarning, isTrue);
    expect(TransportPhase.offline.isError, isTrue);
    expect(TransportPhase.reconnecting.isConnecting, isTrue);
    expect(
      TransportPhase.connected.toneColor('połączony'),
      const Color(0xff61d095),
    );
  });
}
