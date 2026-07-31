import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/domain.dart';
import 'app_controller_legacy.dart' as legacy;
import 'pairing_recovery_app_controller.dart';

class NotificationSafeAppController extends PairingRecoveryAppController {
  static const _legacyPairingNoticePrefix = 'Oczekujące zaproszenia:';
  bool _clearingLegacyNotice = false;

  @override
  legacy.AppState build() {
    final initial = super.build();
    listenSelf((_, next) {
      if (_clearingLegacyNotice ||
          !next.notice.startsWith(_legacyPairingNoticePrefix)) {
        return;
      }
      _clearingLegacyNotice = true;
      state = state.copyWith(notice: '');
      _clearingLegacyNotice = false;
    });
    return initial.notice.startsWith(_legacyPairingNoticePrefix)
        ? initial.copyWith(notice: '')
        : initial;
  }

  @override
  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    if (!preferences.containsKey('torchat.privacy.readReceipts')) {
      await preferences.setBool('torchat.privacy.readReceipts', false);
    }
    await super.initialize();
  }

  @override
  Future<void> openOrStartConversation(ContactRecord contact) async {
    final alreadyExists = state.conversations.any(
      (conversation) => conversation.contactId == contact.id,
    );
    if (alreadyExists) {
      await super.openOrStartConversation(contact);
      return;
    }

    final operation = super.openOrStartConversation(contact);
    final optimistic = ConversationSummary(
      id: contact.id,
      contactId: contact.id,
      preview: 'Oczekiwanie na bezpieczne połączenie…',
      unread: 0,
      state: ConversationState.pending,
      lastMessageAt: DateTime.now().toIso8601String(),
    );
    state = state.copyWith(
      conversations: [
        optimistic,
        for (final conversation in state.conversations)
          if (conversation.contactId != contact.id) conversation,
      ],
      selectedConversationId: contact.id,
      destination: legacy.MainDestination.chats,
    );

    await operation;

    final realConversationExists = state.conversations.any(
      (conversation) => conversation.contactId == contact.id,
    );
    if (state.error.trim().isNotEmpty) {
      state = state.copyWith(
        conversations: [
          for (final conversation in state.conversations)
            if (conversation.contactId != contact.id ||
                conversation.id != contact.id)
              conversation,
        ],
      );
    } else if (!realConversationExists) {
      state = state.copyWith(conversations: [optimistic, ...state.conversations]);
    }
  }
}
