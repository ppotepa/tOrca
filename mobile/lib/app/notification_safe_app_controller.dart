import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/models/domain.dart';
import '../core/relationships/relationship_message.dart';
import 'app_controller_legacy.dart' as legacy;
import 'conversation_navigation_intent.dart';
import 'desktop_notification_service.dart';
import 'pairing_recovery_app_controller.dart';

class NotificationSafeAppController extends PairingRecoveryAppController {
  static const _legacyPairingNoticePrefix = 'Oczekujące zaproszenia:';
  static const _relationshipActiveSincePrefix =
      'torchat.relationship.activeSince.';
  bool _clearingLegacyNotice = false;
  bool _reconcilingRelationshipRemoval = false;
  StreamSubscription<RuntimeEvent>? _notificationEvents;
  final Set<String> _appliedRelationshipRemovalMessageIds = <String>{};

  @override
  legacy.AppState build() {
    final initial = super.build();
    final repository = ref.watch(legacy.runtimeRepositoryProvider);
    _notificationEvents ??= repository.events.listen((event) {
      if (event is DataChangedEvent && event.type == 'notification_opened') {
        ConversationNavigationIntents.openConversation(
          conversationId: event.payload['conversationId']?.toString() ?? '',
          notificationId: event.payload['notificationId']?.toString() ?? '',
        );
        return;
      }
      if (event is! NotificationRequestedEvent) return;
      unawaited(
        DesktopNotificationService.show(
          event,
          selectedConversationId: state.selectedConversationId,
        ),
      );
    });
    ref.onDispose(() => _notificationEvents?.cancel());
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
  Future<void> onPairingContactActivated(ContactRecord contact) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      '$_relationshipActiveSincePrefix${contact.id}',
      DateTime.now().toUtc().toIso8601String(),
    );
    _appliedRelationshipRemovalMessageIds.removeWhere(
      (id) => id.startsWith('preview:${contact.id}:'),
    );
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
    Object? removalDeliveryError;
    StackTrace? removalDeliveryStackTrace;

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
        try {
          await ref
              .read(legacy.runtimeRepositoryProvider)
              .sendMessage(relationshipConversation.id, payload);
        } catch (error, stackTrace) {
          removalDeliveryError = error;
          removalDeliveryStackTrace = stackTrace;
        }
      }
    }

    await super.updateContactSettings(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    );
    if (blocked && relationshipConversation != null) {
      await _cancelPendingOrdinaryMessages(relationshipConversation.id);
      if (!preserveHistory) {
        await _deleteHistoryExceptRemoval(relationshipConversation.id);
      }
    }
    await super.refreshData(forcePairing: false, allowAutoTorka: false);
    _hideRemovedRelationships();

    if (removalDeliveryError != null) {
      Error.throwWithStackTrace(
        StateError(
          'Relacja została usunięta lokalnie, ale komunikat dla kontaktu '
          'nie został zakolejkowany: $removalDeliveryError',
        ),
        removalDeliveryStackTrace ?? StackTrace.current,
      );
    }
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
      final repository = ref.read(legacy.runtimeRepositoryProvider);
      final preferences = await SharedPreferences.getInstance();
      for (final conversation in List<ConversationSummary>.of(state.conversations)) {
        ContactRecord? contact;
        for (final candidate in state.contacts) {
          if (candidate.id == conversation.contactId) {
            contact = candidate;
            break;
          }
        }
        if (contact == null || contact.blocked) continue;

        ChatMessage? removalMessage;
        RelationshipRemovedMessage? removal;
        try {
          final messages = await repository.messages(conversation.id);
          for (final message in messages.reversed) {
            if (message.outgoing) continue;
            final candidate = RelationshipRemovedMessage.tryDecode(message.text);
            if (candidate == null) continue;
            removalMessage = message;
            removal = candidate;
            break;
          }
        } catch (_) {}

        removal ??= RelationshipRemovedMessage.tryDecode(conversation.preview);
        if (removal == null) continue;
        final removalId = removalMessage?.id ??
            'preview:${conversation.id}:${removal.removedAt.toIso8601String()}';
        if (!_appliedRelationshipRemovalMessageIds.add(removalId)) continue;

        final activeSince = DateTime.tryParse(
          preferences.getString(
                '$_relationshipActiveSincePrefix${conversation.contactId}',
              ) ??
              '',
        );
        final storedAt = removalMessage == null
            ? removal.removedAt
            : DateTime.tryParse(removalMessage.createdAt);
        if (activeSince != null &&
            storedAt != null &&
            !storedAt.toUtc().isAfter(activeSince.toUtc())) {
          continue;
        }

        await super.updateContactSettings(
          contact,
          contact.localAlias,
          contact.muted,
          true,
          contact.transportPolicy,
        );
        await _cancelPendingOrdinaryMessages(conversation.id);
        if (!removal.preserveHistory) {
          await _deleteHistoryExceptRemoval(conversation.id);
        }
      }
    } finally {
      _reconcilingRelationshipRemoval = false;
    }
  }

  Future<void> _cancelPendingOrdinaryMessages(String conversationId) async {
    final repository = ref.read(legacy.runtimeRepositoryProvider);
    try {
      final messages = await repository.messages(conversationId);
      for (final message in messages) {
        final pending = message.state == MessageState.queued ||
            message.state == MessageState.sending;
        if (!message.outgoing ||
            !pending ||
            isRelationshipRemovedMessage(message.text)) {
          continue;
        }
        await repository.deleteMessageLocal(message.id);
      }
    } catch (_) {}
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
