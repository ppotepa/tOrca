import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android foreground service uses long-lived messaging semantics', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING'),
    );
    expect(manifest, contains('android:foregroundServiceType="remoteMessaging"'));
    expect(manifest, contains('android:stopWithTask="false"'));
    expect(manifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));
    expect(manifest, isNot(contains('foregroundServiceType="dataSync"')));
  });

  test('Android relay adapter does not own a reconnect loop', () {
    final supervisor = File(
      'android/app/src/main/kotlin/org/torchat/mobile/RelaySupervisor.kt',
    ).readAsStringSync();

    expect(supervisor, contains('Shared Rust relay supervisor'));
    expect(supervisor, isNot(contains('while (scope.isActive)')));
    expect(supervisor, isNot(contains('delay(retryDelayMs)')));
    expect(supervisor, isNot(contains('Random.nextLong')));
  });

  test('Android process lifecycle diagnostics remain registered', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final application = File(
      'android/app/src/main/kotlin/org/torchat/mobile/TorChatApplication.kt',
    ).readAsStringSync();

    expect(manifest, contains('android:name=".TorChatApplication"'));
    expect(application, contains('processInstanceId'));
    expect(application, contains('activity_resumed'));
    expect(application, contains('activity_destroyed'));
  });
}
