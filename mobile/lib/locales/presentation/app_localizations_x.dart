import 'package:flutter/widgets.dart';

import '../../core/models/domain.dart';
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
  String get uiConnectionSummaryDetail => _isPolish
      ? 'Stan infrastruktury komunikacyjnej aplikacji.'
      : 'Application communication infrastructure status.';
  String get uiImageSearchKeyword => _isPolish ? 'obraz' : 'image';
  String uiAttachmentLimitExceeded(int max) => _isPolish
      ? 'Wiadomość może zawierać maksymalnie $max obrazów.'
      : 'A message can contain at most $max images.';
  String get uiAttachmentPreparationFailed => _isPolish
      ? 'Nie udało się przygotować wybranego obrazu.'
      : 'The selected image could not be prepared.';
  String get uiImageSavedToGallery => _isPolish
      ? 'Obraz zapisano w galerii.'
      : 'The image was saved to the gallery.';
  String get uiImageSaveFailed => _isPolish
      ? 'Nie udało się zapisać obrazu w galerii.'
      : 'The image could not be saved to the gallery.';
  String get uiSentImage => _isPolish ? 'Wysłany obraz' : 'Sent image';
  String uiImageFrom(String name) =>
      _isPolish ? 'Obraz od $name' : 'Image from $name';
  String get uiDownloadEncryptedImage => _isPolish
      ? 'Pobierz do zaszyfrowanego magazynu'
      : 'Download to the encrypted store';
  String get uiOpenImagePreview =>
      _isPolish ? 'Otwórz podgląd obrazu' : 'Open image preview';
  String get uiYou => _isPolish ? 'Ty' : 'You';
  String get uiCorruptedImage =>
      _isPolish ? 'obraz uszkodzony' : 'corrupted image';
  String get uiImageReadFailed => _isPolish
      ? 'Nie udało się odczytać obrazu.'
      : 'The image could not be read.';
  String uiRelationshipEndedByYou(String name) => _isPolish
      ? 'Zakończono relację z kontaktem $name.'
      : 'The relationship with $name was ended.';
  String uiRelationshipEndedByContact(String name) => _isPolish
      ? '$name zakończył relację.'
      : '$name ended the relationship.';
  String get uiMessageQueued => _isPolish ? 'w kolejce' : 'queued';
  String get uiMessageSending => _isPolish ? 'wysyłanie' : 'sending';
  String get uiMessageSent => _isPolish ? 'wysłano' : 'sent';
  String get uiMessageDelivered => _isPolish ? 'dostarczono' : 'delivered';
  String get uiMessageRead =>
      _isPolish ? 'dostarczono · odczytano' : 'delivered · read';
  String get uiMessageFailed => _isPolish ? 'błąd' : 'failed';
  String uiMessageState(MessageState state) => switch (state) {
    MessageState.queued => uiMessageQueued,
    MessageState.sending => uiMessageSending,
    MessageState.sent => uiMessageSent,
    MessageState.delivered => uiMessageDelivered,
    MessageState.read => uiMessageRead,
    MessageState.failed => uiMessageFailed,
  };
  String get uiContactCapabilityStatus => _isPolish ? 'Stan' : 'Status';
  String get uiContactCapabilityId => 'ID';
  String get uiContactCapabilitySequence => _isPolish ? 'Sekwencja' : 'Sequence';
  String uiCapabilityStatus(CapabilityStatus status) => switch (status) {
    CapabilityStatus.missing => _isPolish ? 'brak' : 'missing',
    CapabilityStatus.pending => _isPolish ? 'oczekująca' : 'pending',
    CapabilityStatus.active => _isPolish ? 'aktywna' : 'active',
    CapabilityStatus.rotating => _isPolish ? 'odnawianie' : 'rotating',
    CapabilityStatus.revoked => _isPolish ? 'unieważniona' : 'revoked',
    CapabilityStatus.expired => _isPolish ? 'wygasła' : 'expired',
  };
  String get uiContactTransportDiagnostics => _isPolish
      ? 'Diagnostyka transportu DEV'
      : 'DEV transport diagnostics';
  String get uiContactPolicy => _isPolish ? 'Polityka' : 'Policy';
  String get uiContactEffectiveRoute =>
      _isPolish ? 'Efektywna trasa' : 'Effective route';
  String get uiContactEndpointState =>
      _isPolish ? 'Stan endpointu' : 'Endpoint state';
  String get uiContactP2pSessionState =>
      _isPolish ? 'Stan sesji P2P' : 'P2P session state';
  String get uiDeadLetterUnavailable => _isPolish
      ? 'Diagnostyka niedostarczonych operacji jest niedostępna.'
      : 'Undelivered-operation diagnostics are unavailable.';
  String get uiInstallationId => _isPolish ? 'ID instalacji' : 'Installation ID';
  String get uiFingerprint => 'Fingerprint';
  String get uiFingerprintUnavailable => _isPolish
      ? 'Fingerprint niedostępny'
      : 'Fingerprint unavailable';
  String uiRelationshipRemoved(String name) => _isPolish
      ? 'Relacja z $name została zakończona.'
      : 'The relationship with $name was ended.';
  String get uiPendingPairings =>
      _isPolish ? 'Oczekujące parowania' : 'Pending pairings';
  String get uiExpandNavigation =>
      _isPolish ? 'Rozwiń nawigację' : 'Expand navigation';
  String get uiCollapseNavigation =>
      _isPolish ? 'Zwiń nawigację' : 'Collapse navigation';
  String get uiShowDetails => _isPolish ? 'Pokaż szczegóły' : 'Show details';
  String get uiHideDetails => _isPolish ? 'Ukryj szczegóły' : 'Hide details';
  String get uiAccount => _isPolish ? 'Konto' : 'Account';
  String get uiSettings => _isPolish ? 'Ustawienia' : 'Settings';

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
