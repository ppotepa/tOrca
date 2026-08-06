import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../core/runtime/message_paging.dart';
import '../core/runtime/runtime_repository_models.dart';

import '../client_runtime.dart';
import '../core/runtime/runtime_repository.dart';
import '../locales/domain/user_problem.dart';
import '../locales/domain/user_problem_code.dart';
import '../platform/platform_services.dart';
import 'application_state.dart';
import 'conversation_navigation_intent.dart';

class ApplicationNotificationCoordinator {
  ApplicationNotificationCoordinator({
    required RuntimeRepository repository,
    required AppState Function() readState,
    required void Function(AppState) writeState,
  }) : _repository = repository,
       _readState = readState,
       _writeState = writeState;

  static const _activeConversationKey =
      'torchat.notifications.activeConversationId';

  final RuntimeRepository _repository;
  final AppState Function() _readState;
  final void Function(AppState) _writeState;

  AppState get state => _readState();
  set state(AppState value) => _writeState(value);

  Future<void> prepare() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!preferences.containsKey('torchat.privacy.readReceipts')) {
        await preferences.setBool('torchat.privacy.readReceipts', false);
      }
      state = state.copyWith(
        lastSeenEnabled:
            preferences.getBool('torchat.privacy.lastSeen') ?? true,
      );
    } on MissingPluginException {
      // Platform preferences must not block engine startup.
    }
  }

  void handleRuntimeEvent(RuntimeEvent event) {
    if (event is DataChangedEvent && event.type == 'notification_opened') {
      ConversationNavigationIntents.openConversation(
        conversationId: event.payload['conversationId']?.toString() ?? '',
        notificationId: event.payload['notificationId']?.toString() ?? '',
      );
      return;
    }
    if (event is! NotificationRequestedEvent) return;
    unawaited(
      PlatformServices.current.notifications.show(
        event,
        selectedConversationId: state.selectedConversationId,
      ),
    );
  }

  Future<void> persistActiveConversation(String? conversationId) async {
    final SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } on MissingPluginException {
      return;
    }
    final id = conversationId?.trim() ?? '';
    if (id.isEmpty) {
      await preferences.remove(_activeConversationKey);
    } else {
      await preferences.setString(_activeConversationKey, id);
    }
  }

  Future<bool> preserveHistoryForBlock(
    ContactRecord contact,
    bool blocked,
  ) async {
    if (!blocked || contact.blocked) return true;
    final preferences = await SharedPreferences.getInstance();
    final key = 'torchat.relationship.preserveHistory.${contact.id}';
    final preserveHistory = preferences.getBool(key) ?? true;
    await preferences.remove(key);
    return preserveHistory;
  }

  Future<OlderMessagesResult> loadOlderMessages(String conversationId) async {
    if (conversationId.isEmpty ||
        state.selectedConversationId != conversationId) {
      return const OlderMessagesResult(loadedCount: 0, hasMore: false);
    }
    final currentMessages = await _repository.messages(
      conversationId,
      force: false,
    );
    final before = currentMessages.isEmpty ? null : currentMessages.first;
    final page = await _repository.messagePage(
      conversationId,
      before: before,
      limit: defaultMessagePageSize,
    );
    if (page.messages.isEmpty) {
      return OlderMessagesResult(loadedCount: 0, hasMore: page.hasMore);
    }
    final loaded = await _repository.mergeOlderMessagePage(
      conversationId,
      page,
    );
    return OlderMessagesResult(loadedCount: loaded, hasMore: page.hasMore);
  }

  void hideRemovedRelationships() {
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
    if (selectedRemoved) {
      state = state.copyWith(clearSelection: true);
    }
  }

  void showOperationFailure() {
    state = state.copyWith(
      error: '',
      problem: const UserProblem(code: UserProblemCode.operationFailed),
    );
  }
}
