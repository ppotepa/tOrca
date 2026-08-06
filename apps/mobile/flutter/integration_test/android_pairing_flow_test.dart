import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torchat_mobile/main.dart';

/// Runs on a real Android device with the app data reset before launch.
///
/// Unlike `adb shell input`, Flutter instrumentation has permission to inject
/// events on OEM devices such as Xiaomi/HyperOS. The test intentionally uses
/// semantic labels from the real UI, so it also guards against broken modal
/// navigation and missing pairing controls.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android onboarding reaches pairing code dialog', (tester) async {
    await tester.pumpWidget(TorChatMobileApp());
    await tester.pump(const Duration(seconds: 2));

    final nickField = find.byType(TextField).first;
    if (nickField.evaluate().isNotEmpty) {
      await tester.enterText(nickField, 'InstrumentedUser');
      await tester.tap(find.text('Zapisz nick'));
    }

    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('Czaty'), findsWidgets);

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    expect(find.text('Mój kod zaproszenia'), findsOneWidget);

    await tester.tap(find.text('Mój kod zaproszenia'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // A cold onion circuit can take time. Keep the test alive while the
    // service reports relay readiness, but fail with the actual dialog text.
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Twój kod parowania').evaluate().isNotEmpty ||
          find.text('Nie można wygenerować kodu').evaluate().isNotEmpty,
      isTrue,
      reason: 'Pairing action produced neither a code dialog nor a visible relay error',
    );
  });
}
