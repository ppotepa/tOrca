import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_mobile/locales/generated/app_localizations.dart';
import 'package:torchat_mobile/locales/presentation/app_localizations_x.dart';

void main() {
  group('localization contract', () {
    test('declares the supported locales', () {
      expect(
        AppLocalizations.supportedLocales.map((locale) => locale.languageCode),
        containsAll(<String>['en', 'pl']),
      );
    });

    test('English messages expose placeholders and typed adapters', () {
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(l10n.uiPairingAccepted('Alice'), contains('Alice'));
      expect(l10n.uiAttachmentLimitExceeded(4), contains('4'));
      expect(l10n.uiUnreadCountSemantics(3), contains('3'));
      expect(l10n.uiCapabilityStatus(CapabilityStatus.active), isNotEmpty);
      expect(l10n.uiMessageState(MessageState.delivered), isNotEmpty);
      expect(l10n.uiSettingsSaveFailed, isNotEmpty);
    });

    test('Polish messages expose placeholders and typed adapters', () {
      final l10n = lookupAppLocalizations(const Locale('pl'));

      expect(l10n.uiPairingAccepted('Alicja'), contains('Alicja'));
      expect(l10n.uiAttachmentLimitExceeded(4), contains('4'));
      expect(l10n.uiUnreadCountSemantics(3), contains('3'));
      expect(l10n.uiCapabilityStatus(CapabilityStatus.active), isNotEmpty);
      expect(l10n.uiMessageState(MessageState.delivered), isNotEmpty);
      expect(l10n.uiSettingsSaveFailed, isNotEmpty);
    });
  });
}
