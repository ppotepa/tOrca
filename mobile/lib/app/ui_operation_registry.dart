import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/async/async_operation_state.dart';

abstract final class UiOperationKey {
  static const startupShell = 'startup.shell';
  static const contactsLoad = 'contacts.load';
  static const conversationsLoad = 'conversations.load';
  static const nicknameSave = 'profile.nickname.save';
  static const inviteCodeLoad = 'pairing.code.load';
  static const pairingSubmit = 'pairing.submit';
  static const contactSettings = 'contact.settings';
  static const connectionRetry = 'connection.retry';
  static const onionRotate = 'connection.onion.rotate';

  static String conversationOpen(String id) => 'conversation.open:$id';
  static String conversationStart(String id) => 'conversation.start:$id';
  static String messagesLoad(String id) => 'messages.load:$id';
  static String messageSend(String id) => 'message.send:$id';
  static String messageRetry(String id) => 'message.retry:$id';
  static String messageDelete(String id) => 'message.delete:$id';
  static String pairingAccept(String id) => 'pairing.accept:$id';
  static String pairingReject(String id) => 'pairing.reject:$id';
  static String pairingCancel(String id) => 'pairing.cancel:$id';
  static String pairingArchive(String id) => 'pairing.archive:$id';
  static String contactVerify(String id) => 'contact.verify:$id';
  static String contactSettingsFor(String id) => 'contact.settings:$id';
  static String peerRetry(String id) => 'connection.peer.retry:$id';
}

final uiOperationProvider = StateProvider.family<AsyncOperationState, String>(
  (ref, key) => const AsyncOperationState(),
);

extension UiOperationRef on Ref {
  AsyncOperationState operation(String key) => watch(uiOperationProvider(key));
}

mixin UiOperationRunner {
  Ref get operationRef;

  Future<T> runUiOperation<T>(
    String key,
    String label,
    Future<T> Function() operation, {
    String? targetId,
  }) async {
    final notifier = operationRef.read(uiOperationProvider(key).notifier);
    notifier.state = AsyncOperationState(
      phase: AsyncOperationPhase.running,
      label: label,
      targetId: targetId,
    );
    try {
      final value = await operation();
      notifier.state = AsyncOperationState(
        phase: AsyncOperationPhase.succeeded,
        label: label,
        targetId: targetId,
      );
      return value;
    } catch (error) {
      notifier.state = AsyncOperationState(
        phase: AsyncOperationPhase.failed,
        label: label,
        targetId: targetId,
        error: error.toString(),
      );
      rethrow;
    }
  }
}
