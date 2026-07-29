import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../client_runtime.dart';
import '../core/runtime/runtime_contract.dart';
import '../core/runtime/runtime_repository.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
);

enum ControllerScreen { boot, nickname, main }

enum MainDestination { chats, contacts, inbox, account, settings, tor }

class AppState {
  const AppState({
    this.screen = ControllerScreen.boot,
    this.destination = MainDestination.chats,
    this.identity = const RuntimeIdentity(),
    this.profile = const RuntimeProfile(),
    this.contacts = const [],
    this.conversations = const [],
    this.messages = const [],
    this.inbox = const [],
    this.outbox = const [],
    this.ownInvite,
    this.transport = const RuntimeTorStatus(),
    this.selectedConversationId,
    this.isLoading = false,
    this.action = '',
    this.error = '',
    this.notice = '',
  });
  final ControllerScreen screen;
  final MainDestination destination;
  final RuntimeIdentity identity;
  final RuntimeProfile profile;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final List<PairingItem> inbox;
  final List<PairingItem> outbox;
  final InviteCode? ownInvite;
  final RuntimeTorStatus transport;
  final String? selectedConversationId;
  final bool isLoading;
  final String action;
  final String error;
  final String notice;

  int get activeInviteCount => inbox.pendingCount;

  List<ContactRequest> pairingRequests() =>
      inbox.map((invite) => invite.asContactRequest()).toList();

  ConversationSummary? selectedConversation(
    List<ConversationSummary> conversations,
  ) {
    final id = selectedConversationId;
    if (id == null) return null;
    return conversations.firstOrNullWhere((item) => item.id == id);
  }

  ContactRecord? selectedContact(
    List<ContactRecord> contacts,
    List<ConversationSummary> conversations,
  ) {
    final conversation = selectedConversation(conversations);
    if (conversation == null) {
      return selectedConversationId == null
          ? null
          : contacts.firstOrNullWhere(
              (item) => item.id == selectedConversationId,
            );
    }
    return contacts.firstOrNullWhere(
      (item) => item.id == conversation.contactId,
    );
  }

  AppState copyWith({
    ControllerScreen? screen,
    MainDestination? destination,
    RuntimeIdentity? identity,
    RuntimeProfile? profile,
    List<ContactRecord>? contacts,
    List<ConversationSummary>? conversations,
    List<ChatMessage>? messages,
    List<PairingItem>? inbox,
    List<PairingItem>? outbox,
    InviteCode? ownInvite,
    RuntimeTorStatus? transport,
    String? selectedConversationId,
    bool clearSelection = false,
    bool? isLoading,
    String? action,
    String? error,
    String? notice,
  }) => AppState(
    screen: screen ?? this.screen,
    destination: destination ?? this.destination,
    identity: identity ?? this.identity,
    profile: profile ?? this.profile,
    contacts: contacts ?? this.contacts,
    conversations: conversations ?? this.conversations,
    messages: messages ?? this.messages,
    inbox: inbox ?? this.inbox,
    outbox: outbox ?? this.outbox,
    ownInvite: ownInvite ?? this.ownInvite,
    transport: transport ?? this.transport,
    selectedConversationId: clearSelection
        ? null
        : selectedConversationId ?? this.selectedConversationId,
    isLoading: isLoading ?? this.isLoading,
    action: action ?? this.action,
    error: error ?? this.error,
    notice: notice ?? this.notice,
  );
}

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppController extends Notifier<AppState> {
  late final RuntimeRepository _repository;
  StreamSubscription<RuntimeEvent>? _events;

  @override
  AppState build() {
    _repository = ref.watch(runtimeRepositoryProvider);
    ref.onDispose(() {
      _events?.cancel();
    });
    return const AppState();
  }

  Future<void> initialize() async {
    state = state.copyWith(
      screen: ControllerScreen.boot,
      isLoading: true,
      action: OperationAction.connect,
      error: '',
      notice: '',
    );
    _events ??= _repository.events.listen(_handleEvent);
    try {
      await _repository.connect();
      final identity = await _repository.identity();
      final profile = await _repository.profile();
      await refreshData();
      state = state.copyWith(
        identity: identity,
        screen: _screenAfterConnect(profile, state.transport),
        profile: profile,
        isLoading: false,
        action: '',
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        action: '',
        error: _message(error),
      );
    }
  }

  Future<void> refreshData() async {
    final contacts = await _repository.contacts();
    final conversations = await _repository.conversations();
    final inbox = await _repository.inbox();
    final outbox = await _repository.outbox();
    state = state.copyWith(
      contacts: contacts,
      conversations: conversations,
      inbox: inbox,
      outbox: outbox,
    );
  }

  Future<void> retryTor() => initialize();

  Future<void> setNickname(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        profile: profile,
        screen: state.transport.connected
            ? ControllerScreen.main
            : ControllerScreen.boot,
        error: '',
      );
    } catch (error) {
      state = state.copyWith(error: _message(error));
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

  Future<void> openConversation(String id) async {
    try {
      await _repository.openConversation(id);
      final messages = await _repository.messages(id);
      final conversations = await _repository.conversations();
      state = state.copyWith(
        selectedConversationId: id,
        conversations: conversations,
        messages: messages,
        destination: MainDestination.chats,
        error: '',
      );
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> openOrStartConversation(ContactRecord contact) async {
    final existing = state.conversations
        .where((item) => item.contactId == contact.id)
        .firstOrNull;
    if (existing != null) return openConversation(existing.id);
    state = state.copyWith(
      selectedConversationId: contact.id,
      destination: MainDestination.chats,
      action: OperationAction.startConversation,
      error: '',
      notice: 'Oczekiwanie na handshake MLS…',
    );
    try {
      await _repository.startConversation(contact.id);
      await refreshData();
      state = state.copyWith(
        action: '',
        notice: 'Rozmowa została uruchomiona. Oczekuje na handshake MLS.',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  void closeConversation() {
    unawaited(_repository.closeConversation());
    state = state.copyWith(clearSelection: true);
  }

  Future<void> sendMessage(String text) async {
    final id = state.selectedConversationId;
    if (id == null || text.trim().isEmpty) return;
    state = state.copyWith(action: OperationAction.sendMessage, error: '');
    try {
      await _repository.sendMessage(id, text.trim());
      state = state.copyWith(
        messages: await _repository.messages(id),
        action: '',
        notice: '',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  Future<void> submitPairingCode(String code) async {
    final normalizedCode = pairingCodeDigits(code);
    if (normalizedCode == null) {
      state = state.copyWith(error: 'Kod musi zawierać dokładnie 8 cyfr.');
      return;
    }
    state = state.copyWith(
      action: OperationAction.submitPairing,
      error: '',
      notice: '',
    );
    try {
      await _repository.submitPairingCode(normalizedCode);
      await refreshData();
      state = state.copyWith(
        action: '',
        notice: 'Zaproszenie wysłane. Oczekuje na akceptację.',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  Future<InviteCode?> refreshInviteCode() async {
    try {
      state = state.copyWith(
        action: OperationAction.refreshPairing,
        error: '',
        notice: 'Pobieranie kodu z relaya…',
      );
      final code = await _repository.refreshInviteCode();
      if (code != null) {
        state = state.copyWith(
          ownInvite: code,
          action: '',
          error: '',
          notice: '',
        );
      } else {
        state = state.copyWith(
          action: '',
          notice: '',
          error: 'Relay nie zwrócił kodu zaproszenia. Spróbuj ponownie.',
        );
      }
      return code;
    } catch (error) {
      state = state.copyWith(action: '', notice: '', error: _message(error));
      return null;
    }
  }

  Future<void> acceptPairing(String id) async {
    await _runAction(OperationAction.acceptPairing, () async {
      await _repository.acceptPairing(id);
    });
  }

  Future<void> rejectPairing(String id) async {
    await _runAction(OperationAction.rejectPairing, () async {
      await _repository.rejectPairing(id);
    });
  }

  Future<void> archiveInvite(String id) async {
    await _runAction(
      OperationAction.archivePairing,
      () => _repository.archiveInvite(id),
    );
  }

  Future<void> cancelPairing(String id) async {
    await _runAction(OperationAction.cancelPairing, () async {
      await _repository.cancelPairing(id);
    });
  }

  Future<void> verifyContact(String id) async {
    await _runAction(
      OperationAction.verifyContact,
      () => _repository.verifyContact(id),
    );
  }

  Future<void> _runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    state = state.copyWith(action: action, error: '', notice: '');
    try {
      await operation();
      await refreshData();
      state = state.copyWith(action: '', notice: 'Gotowe.');
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  String _message(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
      return switch (error.code) {
        'RUNTIME' =>
          'Operacja nie jest jeszcze dostępna. Poczekaj na połączenie z relayem.',
        _ => 'Operacja nie powiodła się (${error.code}).',
      };
    }
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '');
  }

  void _handleEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeReadyEvent():
        break;
      case TorStatusEvent(:final snapshot):
        state = state.copyWith(
          transport: snapshot,
          screen: _screenAfterConnect(state.profile, snapshot),
        );
      case ProfileReadyEvent(:final profile):
        final nextProfile =
            profile.nickname.trim().isEmpty &&
                state.profile.nickname.trim().isNotEmpty
            ? state.profile
            : profile;
        state = state.copyWith(
          profile: nextProfile,
          screen: _screenAfterConnect(nextProfile, state.transport),
        );
      case DataChangedEvent():
        unawaited(_refreshAfterEvent());
      case RuntimeErrorEvent(:final message):
        state = state.copyWith(error: message);
      case RuntimeLogEvent():
        // Diagnostics are not a data mutation and must not trigger network
        // refreshes while the onion connection is warming up.
        break;
      case NotificationRequestedEvent():
        unawaited(_pagerBeep());
    }
  }

  Future<void> _refreshAfterEvent() async {
    try {
      await refreshData();
      final selected = state.selectedConversationId;
      if (selected != null && selected.isNotEmpty) {
        final messages = await _repository.messages(selected);
        state = state.copyWith(messages: messages);
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  ControllerScreen _screenAfterConnect(
    RuntimeProfile profile,
    RuntimeTorStatus transport,
  ) {
    if (!transport.connected) return ControllerScreen.boot;
    if (profile.nickname.trim().isNotEmpty) return ControllerScreen.main;
    return ControllerScreen.nickname;
  }

  Future<void> _pagerBeep() async {
    if (Platform.isAndroid) {
      return;
    }
    if (Platform.isWindows) {
      const channel = MethodChannel('org.torchat/desktop-notifications');
      try {
        await channel.invokeMethod<void>('pagerBeep');
      } on MissingPluginException {
        await SystemSound.play(SystemSoundType.alert);
      } on PlatformException {
        // A visible in-app alert remains available when the native runner is
        // unavailable (for example widget tests).
        await SystemSound.play(SystemSoundType.alert);
      }
      return;
    }
    await SystemSound.play(SystemSoundType.alert);
  }
}
