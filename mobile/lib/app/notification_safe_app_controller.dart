import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/domain.dart';
import '../core/relationships/relationship_message.dart';
import 'app_controller_legacy.dart' as legacy;
import 'pairing_recovery_app_controller.dart';

class NotificationSafeAppController extends PairingRecoveryAppController {
  static const _legacyPairingNoticePrefix = 'Oczekujące zaproszenia:';
  bool _clearingLegacyNotice = false;
  bool _reconcilingRelationshipRemoval = false;

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
    await _reconcileRelationshipRemovals();
    _hideRemovedRelationships();
  }

  @override
  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) async {
    await super.refreshData(
      forcePairing: forcePairing,
      allowAutoTorka: allowAutoTorka,
    );
    await _reconcileRelationshipRemovals();
    _hideRemovedRelationships();
  }

  @override
  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) async {
    ConversationSummary? relationshipConversation;
    var preserveHistory = true;
    if (blocked && !contact.blocked) {
      for (final candidate in state.conversations) {
        if (candidate.contactId == contact.id) {
          relationshipConversation = candidate;
          break;
        }
      }
      final preferences = await SharedPreferences.getInstance();
      final preferenceKey =
          'torchat.relationship.preserveHistory.${contact.id}';
      preserveHistory = preferences.getBool(preferenceKey) ?? true;
      await preferences.remove(preferenceKey);

      if (relationshipConversation != null) {
        final payload = RelationshipRemovedMessage(
          removedAt: DateTime.now(),
          preserveHistory: preserveHistory,
        ).encode();
        await ref
            .read(legacy.runtimeRepositoryProvider)
            .sendMessage(relationshipConversation.id, payload);
      }
    }

    await super.updateContactSettings(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    );
    if (blocked && !preserveHistory && relationshipConversation != null) {
      await _deleteHistoryExceptRemoval(relationshipConversation.id);
    }
    await super.refreshData(forcePairing: false, allowAutoTorka: false);
    _hideRemovedRelationships();
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

  Future<void> _reconcileRelationshipRemovals() async {
    if (_reconcilingRelationshipRemoval) return;
    _reconcilingRelationshipRemoval = true;
    try {
      for (final conversation in List<ConversationSummary>.of(state.conversations)) {
        final removal = RelationshipRemovedMessage.tryDecode(
          conversation.preview,
        );
        if (removal == null) continue;
        ContactRecord? contact;
        for (final candidate in state.contacts) {
          if (candidate.id == conversation.contactId) {
            contact = candidate;
            break;
          }
        }
        if (contact == null || contact.blocked) continue;
        await super.updateContactSettings(
          contact,
          contact.localAlias,
          contact.muted,
          true,
          contact.transportPolicy,
        );
        if (!removal.preserveHistory) {
          await _deleteHistoryExceptRemoval(conversation.id);
        }
      }
    } finally {
      _reconcilingRelationshipRemoval = false;
    }
  }

  Future<void> _deleteHistoryExceptRemoval(String conversationId) async {
    final repository = ref.read(legacy.runtimeRepositoryProvider);
    final messages = await repository.messages(conversationId);
    for (final message in messages) {
      if (isRelationshipRemovedMessage(message.text)) continue;
      await repository.deleteMessageLocal(message.id);
    }
  }

  void _hideRemovedRelationships() {
    final removed = state.contacts
        .where((contact) => contact.blocked)
        .map((contact) => contact.id)
        .toSet();
    if (removed.isEmpty) return;
    final selectedRemoved = state.selectedConversationId != null &&
        state.conversations.any(
          (conversation) =>
              conversation.id == state.selectedConversationId &&
              removed.contains(conversation.contactId),
        );
    state = state.copyWith(
      contacts: [
        for (final contact in state.contacts)
          if (!removed.contains(contact.id)) contact,
      ],
      conversations: [
        for (final conversation in state.conversations)
          if (!removed.contains(conversation.contactId)) conversation,
      ],
      clearSelection: selectedRemoved,
      notice: selectedRemoved
          ? 'Relacja z kontaktem została zakończona.'
          : state.notice,
    );
  }
}
