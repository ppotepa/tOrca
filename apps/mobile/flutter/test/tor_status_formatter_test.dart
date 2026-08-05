import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

void main() {
  test('tor status helper maps phases, labels and tone consistently', () {
    expect(TransportPhase.fromValue('connecting'), TransportPhase.connecting);
    expect(() => TransportPhase.fromValue('ready'), throwsFormatException);
    expect(
      TransportPhase.fromValue('bootstrapping').name,
      'bootstrapping',
    );
    expect(TransportPhase.connected.isConnected, isTrue);
    expect(TransportPhase.degraded.isWarning, isTrue);
    expect(TransportPhase.offline.isError, isTrue);
    expect(TransportPhase.reconnecting.isConnecting, isTrue);
    expect(TransportPhase.connected.name, 'connected');
  });
}
