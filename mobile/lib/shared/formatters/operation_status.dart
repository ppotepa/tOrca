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

String? operationLabel(String action) => switch (action) {
  OperationAction.connect => 'Łączenie z onion relayem…',
  OperationAction.refreshPairing => 'Generowanie jednorazowego kodu…',
  OperationAction.submitPairing => 'Wysyłanie zaproszenia…',
  OperationAction.acceptPairing => 'Akceptowanie zaproszenia…',
  OperationAction.rejectPairing => 'Odrzucanie zaproszenia…',
  OperationAction.archivePairing => 'Archiwizowanie zaproszenia…',
  OperationAction.cancelPairing => 'Anulowanie zaproszenia…',
  OperationAction.startConversation => 'Uruchamianie rozmowy…',
  OperationAction.sendMessage => 'Wysyłanie wiadomości przez onion…',
  OperationAction.verifyContact => 'Potwierdzanie fingerprintu…',
  '' => null,
  _ => 'Wykonywanie operacji…',
};
