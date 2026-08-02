import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_state/application_snapshot.dart';
import '../core/application_state/application_state_store.dart';
import 'app_controller.dart';

final applicationSnapshotProvider = StreamProvider<ApplicationSnapshot?>((ref) {
  final repository = ref.watch(runtimeRepositoryProvider);
  return repository.applicationState.watchApplication();
});

final conversationMessagesProvider =
    StreamProvider.family<ConversationMessagesSnapshot, String>((
      ref,
      id,
    ) async* {
      final repository = ref.watch(runtimeRepositoryProvider);
      yield* repository.applicationState.watchMessages(id);
    });
