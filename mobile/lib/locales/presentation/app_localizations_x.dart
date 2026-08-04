import 'package:flutter/widgets.dart';

import '../generated/app_localizations.dart';

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

extension AppLocalizationsUiCopy on AppLocalizations {
  bool get _isPolish => localeName.toLowerCase().startsWith('pl');

  String get uiUnknownUser => _isPolish ? 'Użytkownik' : 'User';
  String get uiOperationFailed => problemOperationFailed;
  String get uiPairingRefreshFailed => _isPolish
      ? 'Nie udało się odświeżyć kodu.'
      : 'The pairing code could not be refreshed.';
  String get uiPairingFinalizing => pairingAcceptedDescription;
  String get uiPairingWaitingForMls => _isPolish
      ? 'Zaproszenie zaakceptowano. Kontakt pojawi się po zakończeniu bezpiecznej wymiany.'
      : 'The invitation was accepted. The contact will appear after the secure exchange completes.';
  String get uiImageCacheLoadFailed => _isPolish
      ? 'Nie udało się odczytać magazynu obrazów.'
      : 'The image store could not be read.';
  String get uiImagePreferenceSaveFailed => _isPolish
      ? 'Nie udało się zapisać ustawienia pobierania obrazów.'
      : 'The image download preference could not be saved.';
  String get uiImageCacheClearFailed => _isPolish
      ? 'Nie udało się wyczyścić pamięci obrazów.'
      : 'The image cache could not be cleared.';
  String get uiMainWorkspaceSemantics =>
      _isPolish ? 'Główna przestrzeń TorChat' : 'TorChat main workspace';
  String get uiChats => _isPolish ? 'Czaty' : 'Chats';
  String get uiContacts => _isPolish ? 'Kontakty' : 'Contacts';
  String uiUnreadContactsSemantics(int count) => _isPolish
      ? '$count kontaktów z nieprzeczytanymi wiadomościami'
      : '$count contacts with unread messages';
  String get uiStateReady => _isPolish ? 'gotowe' : 'ready';
  String get uiStateFailed => _isPolish ? 'błąd' : 'failed';
  String get uiStateDegraded => _isPolish ? 'ograniczone' : 'degraded';
  String get uiStateStarting => _isPolish ? 'uruchamianie' : 'starting';
  String get uiStateError => _isPolish ? 'błąd' : 'error';

  String get uiCapabilityStatus => _isPolish ? 'Stan' : 'Status';
  String get uiCapabilityId => 'ID';
  String get uiCapabilitySequence => _isPolish ? 'Sekwencja' : 'Sequence';
  String get uiTransportDiagnostics =>
      _isPolish ? 'Diagnostyka transportu DEV' : 'DEV transport diagnostics';
  String get uiPolicy => _isPolish ? 'Polityka' : 'Policy';
  String get uiEffectiveRoute =>
      _isPolish ? 'Efektywna trasa' : 'Effective route';
  String get uiEndpointStatus =>
      _isPolish ? 'Stan endpointu' : 'Endpoint status';
  String get uiP2pSessionStatus =>
      _isPolish ? 'Stan sesji P2P' : 'P2P session status';
  String get uiDeadLetterUnavailable => _isPolish
      ? 'Diagnostyka dead-letter jest niedostępna.'
      : 'Dead-letter diagnostics are unavailable.';
  String get uiInstallationId => 'Installation ID';
  String get uiFingerprint => 'Fingerprint';
  String get uiFingerprintUnavailable =>
      _isPolish ? 'Fingerprint niedostępny' : 'Fingerprint unavailable';
  String uiRelationshipRemoved(String name) => _isPolish
      ? 'Relacja z $name została zakończona.'
      : 'The relationship with $name has ended.';
  String get uiPendingPairings =>
      _isPolish ? 'Oczekujące parowania' : 'Pending pairings';

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
