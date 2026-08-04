import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/locales/generated/app_localizations_en.dart';
import 'package:torchat_mobile/shared/widgets/identity_avatar.dart';

void main() {
  final l10n = AppLocalizationsEn();
  test('activity labels describe the person rather than the transport', () {
    expect(contactActivityLabel(l10n, ContactActivityVisualState.typing), 'typing…');
    expect(
      contactActivityLabel(l10n, ContactActivityVisualState.online),
      'active in the app',
    );
    expect(
      contactActivityLabel(l10n, ContactActivityVisualState.online),
      'active in the app',
    );
  });
}
