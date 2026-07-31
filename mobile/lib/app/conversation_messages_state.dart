import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/runtime/runtime_repository.dart';
import 'app_controller.dart';

final conversationMessagesLoadProvider = StreamProvider.family<
    ConversationMessagesLoadState, String>((ref, conversationId) async* {
  yield ConversationMessagesLoadState(
    conversationId: conversationId,
    phase: ConversationMessagesPhase.idle,
  );
  final repository = ref.watch(runtimeRepositoryProvider);
  await for (final state in repository.messageLoadStates) {
    if (state.conversationId == conversationId) yield state;
  }
});
