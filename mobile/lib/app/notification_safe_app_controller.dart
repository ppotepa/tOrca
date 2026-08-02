import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/models/domain.dart';
import '../core/relationships/relationship_message.dart';
import '../core/runtime/message_paging.dart';
import 'app_controller_base.dart' as base;
import 'conversation_navigation_intent.dart';
import 'desktop_notification_service.dart';
import 'pairing_recovery_app_controller.dart';

class NotificationSafeAppController extends PairingRecoveryAppController {
  static const _pendingPairingNoticePrefix = 'Oczekujące zaproszenia:';
  static const _relationshipActiveSincePrefix =
      'torchat.relationship.activeSince.';
  static const _activeNotificationConversationKey =
      'torchat.notifications.activeConversationId';

  bool _clearingPendingNotice = false;
  final Set<String> _appliedRelationshipRemovalMessageIds = <String>{};

  @override
  base.AppState build() {
    final initial = super.build();
    listenSelf((previous, next) {
      if (previous?.selectedConversationId != next.selectedConversationId) {
        unawaited(_persistActiveConversation(next.selectedConversationId));
      }
      if (_clearingPendingNotice ||
          !next.notice.startsWith(_pendingPairingNoticePrefix)) {
        return;
      }
      _clearingPendingNotice = true;
      state = state.copyWith(notice: '');
      _clearingPendingNotice = false;
    });
    return initial.notice.startsWith(_pendingPairingNoticePrefix)
        ? initial.copyWith(notice: '')
        : initial;
  }

  @override
  void handleRuntimeEventSideEffects(RuntimeEvent event) {
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
  }

  @override
  Future<void> initialize() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!preferences.containsKey('torchat.privacy.readReceipts')) {
        await preferences.setBool('torchat.privacy.readReceipts', false);
      }
    } on MissingPluginException {
      // A host can attach the platform plugins after the engine starts. The
      // preference is only a persistence hint; it must not block runtime boot.
    }
    await super.initialize();
    await _persistActiveConversation(state.selectedConversationId);
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
    _hideRemovedRelationships();
  }

  Future<int> loadOlderMessages(String conversationId) async {
    if (conversationId.isEmpty ||
        state.selectedConversationId != conversationId) {
      return 0;
    }
    final repository = ref.read(base.runtimeRepositoryProvider);
    final currentMessages = await repository.messages(
      conversationId,
      force: false,
    );
    final before = currentMessages.isEmpty ? null : currentMessages.first;
    final page = await repository.messagePage(
      conversationId,
      before: before,
      limit: defaultMessagePageSize,
    );
    if (page.messages.isEmpty) return 0;

    return repository.mergeOlderMessagePage(conversationId, page);
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
              .read(base.runtimeRepositoryProvider)
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
    if (blocked && !contact.blocked) {
      await ref
          .read(base.runtimeRepositoryProvider)
          .removeRelationship(contact.id, preserveHistory: preserveHistory);
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

  Future<void> _persistActiveConversation(String? conversationId) async {
    final SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } on MissingPluginException {
      // Widget/unit tests and headless engine startup have no platform
      // preferences channel. The canonical runtime state remains in the
      // application store, so persistence is optional here.
      return;
    }
    final id = conversationId?.trim() ?? '';
    if (id.isEmpty) {
      await preferences.remove(_activeNotificationConversationKey);
    } else {
      await preferences.setString(_activeNotificationConversationKey, id);
    }
  }

  void _hideRemovedRelationships() {
    final removed = state.contacts
        .where((contact) => contact.blocked)
        .map((contact) => contact.id)
        .toSet();
    if (removed.isEmpty) return;
    final selectedRemoved =
        state.selectedConversationId != null &&
        state.conversations.any(
          (conversation) =>
              conversation.id == state.selectedConversationId &&
              removed.contains(conversation.contactId),
        );
    state = state.copyWith(
      clearSelection: selectedRemoved,
      notice: selectedRemoved
          ? 'Relacja z kontaktem została zakończona.'
          : state.notice,
    );
  }
}
