import 'package:flutter/widgets.dart';

import '../../core/models/domain.dart';
import '../generated/app_localizations.dart';

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

/// Typed presentation adapters built exclusively from generated ARB messages.
extension AppLocalizationsUiCopy on AppLocalizations {
  String get uiUnknownUser => contactsNewContact;
  String get uiOperationFailed => problemOperationFailed;
  String get uiPairingFinalizing => pairingAcceptedDescription;
  String get uiChats => desktopChats;
  String get uiContacts => desktopContacts;
  String get uiImageSearchKeyword => commonImage.toLowerCase();
  String get uiContactCapabilityStatus => desktopStatus;
  String get uiContactCapabilityId => 'ID';
  String get uiContactPolicy => desktopPolicy;
  String get uiContactEffectiveRoute => desktopRoute;
  String get uiContactEndpointState => desktopEndpoint;
  String get uiContactP2pSessionState => desktopP2pConnection;
  String get uiInstallationId => desktopInstallationId;
  String get uiFingerprint => contactFingerprint;
  String get uiAccount => accountTitle;
  String get uiSettings => settingsTitle;
  String get uiSave => commonSave;

  String uiMessageState(MessageState state) => switch (state) {
    MessageState.queued => messageStateQueued,
    MessageState.sending => messageStateSending,
    MessageState.sent => messageStateSent,
    MessageState.delivered => messageStateDelivered,
    MessageState.read => messageStateRead,
    MessageState.failed => messageStateFailed,
  };

  String uiCapabilityStatus(CapabilityStatus status) => switch (status) {
    CapabilityStatus.missing => uiCapabilityMissing,
    CapabilityStatus.pending => uiCapabilityPending,
    CapabilityStatus.active => uiCapabilityActive,
    CapabilityStatus.rotating => uiCapabilityRotating,
    CapabilityStatus.revoked => uiCapabilityRevoked,
    CapabilityStatus.expired => uiCapabilityExpired,
  };
}

@Deprecated('Use AppLocalizations and AppLocalizationsUiCopy directly.')
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
