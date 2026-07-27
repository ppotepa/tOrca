import 'windows_runtime.dart';

/// Platform-neutral contract consumed by the Flutter UI.
abstract interface class ClientRuntime {
  Stream<Map<String, dynamic>> get events;
  Future<bool> connect();
  Future<Map<String, dynamic>?> identity();
  Future<Map<String, dynamic>?> refreshPairingCode();
  Future<Map<String, dynamic>> setNickname(String nickname);
  Future<void> submitPairingCode(String code);
  Future<List<Map<String, dynamic>>> pairingInbox();
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> verifyContact(String installationId);
  Future<List<Map<String, dynamic>>> contacts();
  Future<List<Map<String, dynamic>>> conversations();
  Future<List<Map<String, dynamic>>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> sendMessage(String id, String text);
}

ClientRuntime createClientRuntime() => createPlatformRuntime();
