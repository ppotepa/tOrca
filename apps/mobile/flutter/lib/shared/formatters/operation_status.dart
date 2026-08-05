import '../../locales/generated/app_localizations.dart';

abstract final class OperationAction {
  static const connect = 'connect';
  static const refreshPairing = 'refreshPairing';
  static const submitPairing = 'submitPairing';
  static const acceptPairing = 'acceptPairing';
  static const rejectPairing = 'rejectPairing';
  static const archivePairing = 'archivePairing';
  static const cancelPairing = 'cancelPairing';
  static const startConversation = 'startConversation';
  static const sendMessage = 'sendMessage';
  static const verifyContact = 'verifyContact';
}

String? localizedOperationLabel(AppLocalizations l10n, String action) =>
    switch (action) {
      OperationAction.connect => l10n.statusTransportConnecting,
      OperationAction.refreshPairing => l10n.pairingRefreshing,
      OperationAction.submitPairing => l10n.processingPairingCode,
      OperationAction.acceptPairing => l10n.accepting,
      OperationAction.rejectPairing => l10n.pairingSavingDecision,
      OperationAction.archivePairing || OperationAction.cancelPairing =>
        l10n.settingsSaving,
      OperationAction.startConversation => l10n.chatStarting,
      OperationAction.sendMessage => l10n.messageStateSending,
      OperationAction.verifyContact => l10n.pairingSavingDecision,
      '' => null,
      _ => l10n.settingsSaving,
    };

@Deprecated('Use localizedOperationLabel with AppLocalizations.')
String? operationLabel(String action) => null;
