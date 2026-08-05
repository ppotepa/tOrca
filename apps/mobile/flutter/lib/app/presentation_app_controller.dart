import 'package:torchat_flutter_ui/async/async_operation_state.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

import '../client_runtime.dart';
import '../core/problems/runtime_problem_classifier.dart';
import '../shared/formatters/operation_status.dart';
import 'app_controller_base.dart' as base;
import 'sequential_app_controller.dart';
import 'ui_operation_registry.dart';

/// Presentation-only operation state.
///
/// This controller may expose button progress and sanitized failures, but it
/// must never retry, reconcile or advance a domain workflow. Pairing recovery
/// is owned by the Rust runtime and ClientEngine projection pipeline.
class PresentationAppController extends SequentialAppController {
  bool _sanitizingProblem = false;
  bool _pairingMutationInFlight = false;
  String? _pairingMutationError;

  @override
  base.AppState build() {
    final initial = super.build();
    listenSelf((_, next) {
      if (_pairingMutationInFlight && next.error.trim().isNotEmpty) {
        _pairingMutationError = next.error;
      }
      _sanitizeTechnicalProblem(next.error);
    });
    return initial;
  }

  @override
  Future<void> initialize() async {
    _begin(UiOperationKey.contactsLoad, 'Loading contacts');
    _begin(UiOperationKey.conversationsLoad, 'Loading conversations');
    await super.initialize();
    _finishFromController(UiOperationKey.contactsLoad, 'Loading contacts');
    _finishFromController(
      UiOperationKey.conversationsLoad,
      'Loading conversations',
    );
  }

  @override
  Future<void> retryTor() => _runVoid(
    UiOperationKey.connectionRetry,
    'Retrying connection',
    super.retryTor,
  );

  @override
  Future<void> setNickname(String nickname) => _runVoid(
    UiOperationKey.nicknameSave,
    'Saving nickname',
    () => super.setNickname(nickname),
  );

  @override
  Future<void> openConversation(String id) => _runVoid(
    UiOperationKey.conversationOpen(id),
    'Opening conversation',
    () async {
      _begin(UiOperationKey.messagesLoad(id), 'Loading messages', id);
      await super.openConversation(id);
      _finishFromController(
        UiOperationKey.messagesLoad(id),
        'Loading messages',
        id,
      );
    },
    targetId: id,
  );

  @override
  Future<void> openOrStartConversation(ContactRecord contact) => _runVoid(
    UiOperationKey.conversationStart(contact.id),
    'Starting conversation',
    () => super.openOrStartConversation(contact),
    targetId: contact.id,
  );

  @override
  Future<void> sendMessage(String text, {String? replyToMessageId}) {
    final id = state.selectedConversationId ?? '';
    return _runVoid(
      UiOperationKey.messageSend(id),
      'Sending message',
      () => super.sendMessage(text, replyToMessageId: replyToMessageId),
      targetId: id,
    );
  }

  @override
  Future<void> retryMessage(String messageId) => _runVoid(
    UiOperationKey.messageRetry(messageId),
    'Retrying message',
    () => super.retryMessage(messageId),
    targetId: messageId,
  );

  @override
  Future<void> deleteMessageLocal(String messageId) => _runVoid(
    UiOperationKey.messageDelete(messageId),
    'Deleting message',
    () => super.deleteMessageLocal(messageId),
    targetId: messageId,
  );

  @override
  Future<void> submitPairingCode(String code) => _runPairingMutation(
    UiOperationKey.pairingSubmit,
    'Submitting pairing code',
    () => super.submitPairingCode(code),
  );

  @override
  Future<InviteCode?> refreshInviteCode({bool quietWhenPending = false}) async {
    const key = UiOperationKey.inviteCodeLoad;
    _begin(key, 'Loading pairing code');
    final value = await super.refreshInviteCode(
      quietWhenPending: quietWhenPending,
    );
    _finishFromController(key, 'Loading pairing code');
    return value;
  }

  @override
  Future<void> acceptPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingAccept(id),
    'Accepting invitation',
    () => super.acceptPairing(id),
    targetId: id,
  );

  @override
  Future<void> rejectPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingReject(id),
    'Rejecting invitation',
    () => super.rejectPairing(id),
    targetId: id,
  );

  @override
  Future<void> cancelPairing(String id) => _runPairingMutation(
    UiOperationKey.pairingCancel(id),
    'Cancelling invitation',
    () => super.cancelPairing(id),
    targetId: id,
  );

  @override
  Future<void> archiveInvite(String id) => _runPairingMutation(
    UiOperationKey.pairingArchive(id),
    'Archiving invitation',
    () => super.archiveInvite(id),
    targetId: id,
  );

  @override
  Future<void> verifyContact(String id) => _runVoid(
    UiOperationKey.contactVerify(id),
    'Verifying contact',
    () => super.verifyContact(id),
    targetId: id,
  );

  @override
  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) => _runVoid(
    UiOperationKey.contactSettingsFor(contact.id),
    'Saving contact settings',
    () => super.updateContactSettings(
      contact,
      localAlias,
      muted,
      blocked,
      transportPolicy,
    ),
    targetId: contact.id,
  );

  Future<void> _runPairingMutation(
    String key,
    String label,
    Future<void> Function() operation, {
    String? targetId,
  }) async {
    _pairingMutationError = null;
    _pairingMutationInFlight = true;
    try {
      await _runVoid(key, label, operation, targetId: targetId);
    } finally {
      _pairingMutationInFlight = false;
    }
    final error = (_pairingMutationError ?? state.error).trim();
    if (error.isNotEmpty) throw StateError(error);
  }

  Future<void> _runVoid(
    String key,
    String label,
    Future<void> Function() operation, {
    String? targetId,
  }) async {
    _begin(key, label, targetId);
    try {
      await operation();
    } finally {
      _finishFromController(key, label, targetId);
    }
  }

  void _begin(String key, String label, [String? targetId]) {
    ref.read(uiOperationProvider(key).notifier).state = AsyncOperationState(
      phase: AsyncOperationPhase.running,
      label: label,
      targetId: targetId,
    );
  }

  void _finishFromController(String key, String label, [String? targetId]) {
    final error = state.error.trim();
    final classification = classifyRuntimeProblem(error);
    final visibleError = classification.userVisible ? error : '';
    try {
      ref.read(uiOperationProvider(key).notifier).state = AsyncOperationState(
        phase: visibleError.isEmpty
            ? AsyncOperationPhase.succeeded
            : AsyncOperationPhase.failed,
        label: label,
        targetId: targetId,
        error: visibleError,
      );
    } on StateError {
      // The provider may have been disposed while an async platform operation
      // was completing. Its result is no longer observable.
    }
  }

  void _sanitizeTechnicalProblem(String message) {
    if (_sanitizingProblem || message.trim().isEmpty) return;
    final classification = classifyRuntimeProblem(message);
    if (classification.userVisible) return;
    _sanitizingProblem = true;
    state = state.copyWith(error: '');
    _sanitizingProblem = false;
  }
}
