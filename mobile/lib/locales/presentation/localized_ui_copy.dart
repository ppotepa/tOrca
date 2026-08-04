import '../generated/app_localizations.dart';

final class LocalizedUiCopy {
  const LocalizedUiCopy(this.l10n);

  final AppLocalizations l10n;

  bool get _polish => l10n.localeName.toLowerCase().startsWith('pl');

  String get unknownUser => _polish ? 'Użytkownik' : 'User';

  String pairingAccepted(String name) => _polish
      ? '$name przyjął Twoje zaproszenie.'
      : '$name accepted your invitation.';

  String pairingRejected(String name) => _polish
      ? '$name odrzucił Twoje zaproszenie.'
      : '$name rejected your invitation.';

  String get pairingExpired => _polish
      ? 'Zaproszenie wygasło bez odpowiedzi.'
      : 'The invitation expired without a response.';

  String get pairingCancelled => _polish
      ? 'Zaproszenie zostało anulowane.'
      : 'The invitation was cancelled.';

  String contactAdded(String name) =>
      _polish ? 'Dodano kontakt $name.' : 'Added contact $name.';

  String get resetLocalStateInstructions => _polish
      ? 'Reset lokalnego stanu wykonaj przez wdrożenie z opcją resetu.'
      : 'Reset local state by deploying with the reset option.';

  String get editNickname => _polish ? 'Edytuj nick' : 'Edit nickname';

  String get save => _polish ? 'Zapisz' : 'Save';

  String get settingsSaveFailed => _polish
      ? 'Nie udało się zapisać ustawienia.'
      : 'The setting could not be saved.';

  String get windowsAutostartNotConfirmed => _polish
      ? 'System Windows nie potwierdził zmiany autostartu.'
      : 'Windows did not confirm the autostart change.';
}
