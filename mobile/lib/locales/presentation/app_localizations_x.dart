import 'package:flutter/widgets.dart';

import '../generated/app_localizations.dart';

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? lookupAppLocalizations(const Locale('pl'));
}

extension AppLocalizationsUiCopy on AppLocalizations {
  bool get _isPolish => localeName.toLowerCase().startsWith('pl');

  String get uiUnknownUser => _isPolish ? 'Użytkownik' : 'User';

  String uiPairingAccepted(String name) => _isPolish
      ? '$name przyjął Twoje zaproszenie.'
      : '$name accepted your invitation.';

  String uiPairingRejected(String name) => _isPolish
      ? '$name odrzucił Twoje zaproszenie.'
      : '$name rejected your invitation.';

  String get uiPairingExpired => _isPolish
      ? 'Zaproszenie wygasło bez odpowiedzi.'
      : 'The invitation expired without a response.';

  String get uiPairingCancelled => _isPolish
      ? 'Zaproszenie zostało anulowane.'
      : 'The invitation was cancelled.';

  String uiContactAdded(String name) =>
      _isPolish ? 'Dodano kontakt $name.' : 'Added contact $name.';

  String get uiResetLocalStateInstructions => _isPolish
      ? 'Reset lokalnego stanu wykonaj przez wdrożenie z opcją resetu.'
      : 'Reset local state by deploying with the reset option.';

  String get uiEditNickname => _isPolish ? 'Edytuj nick' : 'Edit nickname';

  String get uiSave => _isPolish ? 'Zapisz' : 'Save';

  String get uiSettingsSaveFailed => _isPolish
      ? 'Nie udało się zapisać ustawienia.'
      : 'The setting could not be saved.';

  String get uiWindowsAutostartNotConfirmed => _isPolish
      ? 'System Windows nie potwierdził zmiany autostartu.'
      : 'Windows did not confirm the autostart change.';
}

@Deprecated('Use AppLocalizationsUiCopy directly on AppLocalizations.')
final class LocalizedUiCopy {
  const LocalizedUiCopy(this.l10n);

  final AppLocalizations l10n;

  String get unknownUser => l10n.uiUnknownUser;
  String pairingAccepted(String name) => l10n.uiPairingAccepted(name);
  String pairingRejected(String name) => l10n.uiPairingRejected(name);
  String get pairingExpired => l10n.uiPairingExpired;
  String get pairingCancelled => l10n.uiPairingCancelled;
  String contactAdded(String name) => l10n.uiContactAdded(name);
  String get resetLocalStateInstructions => l10n.uiResetLocalStateInstructions;
  String get editNickname => l10n.uiEditNickname;
  String get save => l10n.uiSave;
  String get settingsSaveFailed => l10n.uiSettingsSaveFailed;
  String get windowsAutostartNotConfirmed =>
      l10n.uiWindowsAutostartNotConfirmed;
}
