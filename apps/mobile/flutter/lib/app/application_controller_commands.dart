part of 'application_controller.dart';

extension ApplicationControllerCommands on ApplicationController {
  Future<void> setNickname(String nickname) => _runPresented(
    UiOperationKey.nicknameSave,
    'Saving nickname',
    () => _setNicknameCore(nickname),
  );

  Future<void> openConversation(String id) => _runPresented(
    UiOperationKey.conversationOpen(id),
    'Opening conversation',
    () => _openConversationCore(id),
    targetId: id,
  );

  Future<void> openOrStartConversation(ContactRecord contact) => _runPresented(
    UiOperationKey.conversationStart(contact.id),
    'Starting conversation',
    () => _openOrStartConversationCore(contact),
    targetId: contact.id,
  );

  Future<void> sendMessage(String text, {String? replyToMessageId}) {
    final id = state.selectedConversationId ?? '';
    return _runPresented(
      UiOperationKey.messageSend(id),
      'Sending message',
      () => _sendMessageCore(text, replyToMessageId: replyToMessageId),
      targetId: id,
    );
  }

  Future<void> retryMessage(String messageId) => _runPresented(
    UiOperationKey.messageRetry(messageId),
    'Retrying message',
    () => _retryMessageCore(messageId),
    targetId: messageId,
  );

  Future<void> deleteMessageLocal(String messageId) => _runPresented(
    UiOperationKey.messageDelete(messageId),
    'Deleting message',
    () => _deleteMessageLocalCore(messageId),
    targetId: messageId,
  );

  Future<void> submitPairingCode(String code) => _runPresented(
    UiOperationKey.pairingSubmit,
    'Submitting pairing code',
    () => _submitPairingCodeCore(code),
  );

  Future<InviteCode?> refreshInviteCode({bool quietWhenPending = false}) =>
      _runPresented(
        UiOperationKey.inviteCodeLoad,
        'Loading pairing code',
        () => _refreshInviteCodeCore(quietWhenPending: quietWhenPending),
      );

  Future<void> acceptPairing(String id) => _runPresented(
    UiOperationKey.pairingAccept(id),
    'Accepting invitation',
    () => _acceptPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> rejectPairing(String id) => _runPresented(
    UiOperationKey.pairingReject(id),
    'Rejecting invitation',
    () => _rejectPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> archiveInvite(String id) => _runPresented(
    UiOperationKey.pairingArchive(id),
    'Archiving invitation',
    () => _archiveInviteCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> cancelPairing(String id) => _runPresented(
    UiOperationKey.pairingCancel(id),
    'Cancelling invitation',
    () => _cancelPairingCore(id),
    targetId: id,
    throwOnFailure: true,
  );

  Future<void> verifyContact(String id) => _runPresented(
    UiOperationKey.contactVerify(id),
    'Verifying contact',
    () => _verifyContactCore(id),
    targetId: id,
  );

  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) => _runPresented(
    UiOperationKey.contactSettingsFor(contact.id),
    'Saving contact settings',
    () => _updateContactSettingsCore(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    ),
    targetId: contact.id,
  );

  Future<void> _setNicknameCore(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: state.peerServerStatus,
        ),
        error: '',
      );
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  void selectDestination(MainDestination destination) {
    if (destination != MainDestination.chats) {
      unawaited(_repository.closeConversation());
    }
    state = state.copyWith(
      destination: destination,
      clearSelection: true,
      error: '',
    );
  }

  Future<void> _openConversationCore(String id) async {
    try {
      final conversation = state.conversations.firstOrNullWhere(
        (item) => item.id == id || item.contactId == id,
      );
      final activated = await _repository.activateConversation(
        conversation?.contactId ?? id,
      );
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
        selectedConversationId: activated.conversation.id,
        destination: MainDestination.chats,
        error: '',
      );
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _openOrStartConversationCore(ContactRecord contact) async {
    state = state.copyWith(
      destination: MainDestination.chats,
      action: OperationAction.startConversation,
      error: '',
    );
    try {
      final activated = await _repository.activateConversation(contact.id);
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
        selectedConversationId: activated.conversation.id,
        action: '',
      );
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  void closeConversation() {
    unawaited(_repository.closeConversation());
    state = state.copyWith(clearSelection: true);
  }

  Future<void> _sendMessageCore(String text, {String? replyToMessageId}) async {
    final id = state.selectedConversationId;
    if (id == null || text.trim().isEmpty) return;
    state = state.copyWith(action: OperationAction.sendMessage, error: '');
    try {
      await _repository.sendMessage(
        id,
        text.trim(),
        replyToMessageId: replyToMessageId,
      );
      state = state.copyWith(
        applicationSnapshot:
            _repository.currentApplicationSnapshot ?? state.applicationSnapshot,
        action: '',
      );
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _retryMessageCore(String messageId) async {
    try {
      await _repository.retryMessage(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
      }
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _deleteMessageLocalCore(String messageId) async {
    try {
      await _repository.deleteMessageLocal(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        await _repository.messages(conversationId, force: true);
      }
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> setTyping(bool typing) async {
    final conversationId = state.selectedConversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!(preferences.getBool('torchat.privacy.typing') ?? true)) return;
      await _repository.setTyping(conversationId, typing);
    } catch (_) {
      // Best-effort transient signal.
    }
  }

  Future<void> setConversationFocus(String conversationId, bool focused) async {
    final result = await _repository.setConversationFocus(
      conversationId,
      focused,
    );
    if (result?.status == ReadReceiptQueueStatus.error) {
      state = state.copyWith(
        error: 'Unable to queue read receipt: ${result!.error}',
        problem: const UserProblem(code: UserProblemCode.operationFailed),
      );
    }
  }

  Future<void> updateVisibility(bool foreground) async {
    final conversationId = state.selectedConversationId;
    if (!foreground && conversationId != null) {
      await _repository.setConversationFocus(conversationId, false);
    }
    await _repository.updateAppVisibility(foreground);
    if (foreground && conversationId != null) {
      await _repository.setConversationFocus(conversationId, true);
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final enabled = preferences.getBool('torchat.privacy.presence') ?? true;
      await _repository.setPresence(foreground && enabled);
    } catch (_) {
      // Best-effort presence update.
    }
  }

  Future<void> _submitPairingCodeCore(String code) async {
    if (!state.transport.connected ||
        !state.connectionReadiness.canPerform(ConnectionOperation.pair)) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.connectionUnavailable),
      );
      return;
    }
    final profile = await _repository.profile(force: true);
    if (profile.nickname.trim().length < 2) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.nicknameRequired),
      );
      return;
    }
    final normalizedCode = pairingCode(code);
    if (normalizedCode == null) {
      state = state.copyWith(
        error: '',
        problem: const UserProblem(code: UserProblemCode.pairingCodeInvalid),
      );
      return;
    }
    state = state.copyWith(action: OperationAction.submitPairing, error: '');
    try {
      await _repository.submitPairingCode(normalizedCode);
      await refreshData();
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<InviteCode?> _refreshInviteCodeCore({
    bool quietWhenPending = false,
  }) async {
    if (!state.connectionReadiness.canPerform(ConnectionOperation.pair)) {
      if (!quietWhenPending) {
        state = state.copyWith(
          action: '',
          error: '',
          problem: const UserProblem(
            code: UserProblemCode.secureConnectionPending,
          ),
        );
      }
      return null;
    }
    try {
      state = state.copyWith(action: OperationAction.refreshPairing, error: '');
      final code = await _repository.refreshInviteCode();
      if (code != null) {
        state = state.copyWith(ownInvite: code, action: '', error: '');
      } else {
        state = state.copyWith(
          action: '',
          error: '',
          problem: const UserProblem(
            code: UserProblemCode.inviteCodeUnavailable,
          ),
        );
      }
      return code;
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
      return null;
    }
  }

  Future<void> _acceptPairingCore(String id) async {
    await _runAction(OperationAction.acceptPairing, () async {
      await _repository.acceptPairing(id);
    });
  }

  Future<void> _rejectPairingCore(String id) async {
    await _runAction(OperationAction.rejectPairing, () async {
      await _repository.rejectPairing(id);
    });
  }

  Future<void> _archiveInviteCore(String id) async {
    await _runAction(
      OperationAction.archivePairing,
      () => _repository.archiveInvite(id),
    );
  }

  Future<void> _cancelPairingCore(String id) async {
    await _runAction(OperationAction.cancelPairing, () async {
      await _repository.cancelPairing(id);
    });
  }

  Future<void> _verifyContactCore(String id) async {
    await _runAction(
      OperationAction.verifyContact,
      () => _repository.verifyContact(id),
    );
  }

  Future<void> _updateContactSettingsCore(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) async {
    final preserveHistory = await _notifications.preserveHistoryForBlock(
      contact,
      blocked,
    );
    try {
      await _repository.updateContactSettings(
        contact.id,
        localAlias: localAlias,
        muted: muted,
        blocked: blocked,
        transportPolicy: transportPolicy,
      );
      final snapshot = await _repository.applicationSnapshot(force: true);
      state = state.copyWith(applicationSnapshot: snapshot, error: '');
      if (blocked && !contact.blocked) {
        await _repository.removeRelationship(
          contact.id,
          preserveHistory: preserveHistory,
        );
        await refreshData();
      }
      _notifications.hideRemovedRelationships();
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }

  Future<void> _runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    state = state.copyWith(action: action, error: '');
    try {
      await operation();
      await refreshData();
      state = state.copyWith(action: '');
    } catch (error) {
      state = state.copyWith(
        action: '',
        error: _message(error),
        problem: problemForError(error),
      );
    }
  }
}
