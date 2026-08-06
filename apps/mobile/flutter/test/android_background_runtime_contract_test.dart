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
    expect(
      manifest,
      contains('android:foregroundServiceType="remoteMessaging"'),
    );
    expect(manifest, contains('android:stopWithTask="false"'));
    expect(manifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));
    expect(manifest, isNot(contains('foregroundServiceType="dataSync"')));
  });

  test('Android foreground service has no global relay supervisor', () {
    final service = File(
      'android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt',
    ).readAsStringSync();

    expect(service, isNot(contains('RelaySupervisor')));
    expect(service, isNot(contains('relay_ready')));
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

  test('Android UI reattach restores the complete lightweight shell', () {
    final bridge = File(
      'lib/platform/android/mobile_bridge.dart',
    ).readAsStringSync();
    final runtime = File('lib/client_runtime.dart').readAsStringSync();

    // Reattach uses the atomic application projection; independent contact
    // and conversation calls would recreate mixed-revision state.
    expect(bridge, contains('EngineContract.getApplicationSnapshot'));
    expect(bridge, contains("snapshot['serviceAlive']"));
    expect(bridge, isNot(contains('EngineContract.listMessages')));
    expect(runtime, isNot(contains('ApplicationStateStore.shared.hydrate')));
    expect(
      runtime,
      contains('belong to the revisioned application projection'),
    );
  });
}
