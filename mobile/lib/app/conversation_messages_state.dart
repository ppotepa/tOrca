import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/runtime/runtime_repository.dart';
import 'app_controller.dart';

final conversationMessagesLoadEventsProvider =
    StreamProvider<ConversationMessagesLoadState>((ref) {
  return ref.watch(runtimeRepositoryProvider).messageLoadStates;
});

final conversationMessagesLoadProvider = StreamProvider.family<
    ConversationMessagesLoadState, String>((ref, conversationId) async* {
  yield ConversationMessagesLoadState(
    conversationId: conversationId,
    phase: ConversationMessagesPhase.idle,
  );
  await for (final state
      in ref.watch(runtimeRepositoryProvider).messageLoadStates) {
    if (state.conversationId == conversationId) yield state;
  }
});
