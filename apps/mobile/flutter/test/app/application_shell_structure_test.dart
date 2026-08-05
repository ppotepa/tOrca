import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main is a bootstrap and app shell is split by responsibility', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final appSource = File('lib/app/torca_app.dart').readAsStringSync();
    final rootSource = File('lib/app/application_root.dart').readAsStringSync();
    final dialogSource = File(
      'lib/app/application_dialogs.dart',
    ).readAsStringSync();

    expect(mainSource, contains('runApp(const TorcaApp())'));
    expect(mainSource.contains('class ControllerHomePage'), isFalse);
    expect(mainSource.contains('MaterialApp('), isFalse);
    expect(appSource, contains('class TorcaApp'));
    expect(rootSource, contains('class ControllerHomePage'));
    expect(dialogSource, contains('extension _ApplicationDialogs'));
    expect(rootSource.contains('Future<void>.delayed'), isFalse);
    expect(dialogSource.contains('Future<void>.delayed'), isFalse);
    expect(rootSource.contains('forcePairing'), isFalse);
    expect(dialogSource.contains('forcePairing'), isFalse);
    expect(rootSource.contains('allowAutoTorka'), isFalse);
    expect(dialogSource.contains('allowAutoTorka'), isFalse);
  });
}
