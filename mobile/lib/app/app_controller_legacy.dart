import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client_runtime.dart';
import '../core/runtime/runtime_repository.dart';
import '../core/runtime/generated/runtime_contract.g.dart';
import '../shared/formatters/invite_code.dart';
import '../shared/formatters/operation_status.dart';

final clientRuntimeProvider = Provider<ClientRuntime>(
  (ref) => createClientRuntime(),
);

final runtimeRepositoryProvider = Provider<RuntimeRepository>(
  (ref) => RuntimeRepository(ref.watch(clientRuntimeProvider)),
);

const _devTorkaPairingCode = String.fromEnvironment(
  'TORCHAT_TORKA_PAIRING_CODE',
  defaultValue: '',
);

@visibleForTesting
String? debugTorkaPairingCodeOverride;

@visibleForTesting
Duration? debugTorkaWatchdogIntervalOverride;

@visibleForTesting
int? debugTorkaWatchdogMaxAttemptsOverride;

enum ControllerScreen { boot, nickname, main }

enum MainDestination { chats, contacts, account, settings, tor }

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
    this.peerServerStatus = PeerServerStatus.starting,
    this.startupSteps = const [],
    this.selectedConversationId,
    this.isLoading = false,
    this.action = '',
    this.error = '',
    this.notice = '',
    this.typingContacts = const {},
    this.onlineContacts = const {},
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
  final PeerServerStatus peerServerStatus;
  final List<StartupStep> startupSteps;
  final String? selectedConversationId;
  final bool isLoading;
  final String action;
  final String error;
  final String notice;
  final Map<String, bool> typingContacts;
  final Map<String, bool> onlineContacts;

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
    PeerServerStatus? peerServerStatus,
    List<StartupStep>? startupSteps,
    String? selectedConversationId,
    bool clearSelection = false,
    bool? isLoading,
    String? action,
    String? error,
    String? notice,
    Map<String, bool>? typingContacts,
    Map<String, bool>? onlineContacts,
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
    peerServerStatus: peerServerStatus ?? this.peerServerStatus,
    startupSteps: startupSteps ?? this.startupSteps,
    selectedConversationId: clearSelection
        ? null
        : selectedConversationId ?? this.selectedConversationId,
    isLoading: isLoading ?? this.isLoading,
    action: action ?? this.action,
    error: error ?? this.error,
    notice: notice ?? this.notice,
    typingContacts: typingContacts ?? this.typingContacts,
    onlineContacts: onlineContacts ?? this.onlineContacts,
  );
}

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppController extends Notifier<AppState> {
  late final RuntimeRepository _repository;
  StreamSubscription<RuntimeEvent>? _events;
  bool _introPlayed = false;
  bool _torkaPairingInFlight = false;
  bool _torkaConversationInFlight = false;
  String? _torkaInstallationIdHint;
  Timer? _torkaWatchdog;
  int _torkaWatchdogAttempts = 0;
  final Map<String, Timer> _typingExpiry = {};

  @override
  AppState build() {
    _repository = ref.watch(runtimeRepositoryProvider);
    ref.onDispose(() {
      _events?.cancel();
      _torkaWatchdog?.cancel();
      for (final timer in _typingExpiry.values) {
        timer.cancel();
      }
    });
    return const AppState();
  }

  Future<void> initialize() async {
    state = state.copyWith(
      screen: ControllerScreen.boot,
      isLoading: true,
      startupSteps: _startupSteps(
        initialStartupSteps(),
        StartupStepKind.engine,
        StartupStepState.running,
        'Uruchamianie wspólnego engine',
      ),
      action: OperationAction.connect,
      error: '',
      notice: '',
    );
    _events ??= _repository.events.listen(_handleEvent);
    try {
      await _repository.connect();
      final identity = await _repository.identity();
      final profile = await _repository.profile();
      state = state.copyWith(identity: identity, profile: profile);
      await refreshData();
      state = state.copyWith(
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: state.peerServerStatus,
        ),
        profile: profile,
        isLoading: false,
        action: '',
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        action: '',
        error: _message(error),
        startupSteps: _startupSteps(
          state.startupSteps,
          StartupStepKind.engine,
          StartupStepState.error,
          _message(error),
        ),
      );
    }
  }

  Future<void> refreshData({
    bool forcePairing = false,
    bool allowAutoTorka = true,
  }) async {
    late final List<ContactRecord> contacts;
    late final List<ConversationSummary> conversations;
    late final List<PairingItem> inbox;
    late final List<PairingItem> outbox;
    late final bool peerEndpointAvailable;

    if (forcePairing) {
      final snapshot = await _repository.refresh(
        includePairing: true,
        bypassCooldown: true,
      );
      contacts = _mergeRefreshedContacts(snapshot.local.contacts);
      conversations = snapshot.local.conversations;
      inbox = snapshot.pairing?.inbox ?? const [];
      outbox = snapshot.pairing?.outbox ?? const [];
      peerEndpointAvailable = snapshot.local.peerEndpointAvailable;
    } else {
      contacts = _mergeRefreshedContacts(await _repository.contacts());
      conversations = await _repository.conversations();
      inbox = await _repository.inbox();
      outbox = await _repository.outbox();
      peerEndpointAvailable = await _repository.peerEndpointAvailable();
    }
    final peerServerStatus = _peerServerStatusForRefresh(
      state.transport,
      peerEndpointAvailable,
      current: state.peerServerStatus,
    );
    state = state.copyWith(
      contacts: contacts,
      conversations: conversations,
      inbox: inbox,
      outbox: outbox,
      peerServerStatus: peerServerStatus,
      startupSteps: _startupStepsForEndpoint(
        state.startupSteps,
        peerEndpointAvailable,
        torReady: state.transport.usable,
        relayReady: state.transport.connected,
        peerServerStatus: peerServerStatus,
      ),
    );
    if (state.transport.connected) {
      state = state.copyWith(
        screen: _screenAfterConnect(
          state.profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: peerServerStatus,
        ),
      );
      if (allowAutoTorka) {
        unawaited(_maybeAutoPairTorka());
      }
    }
  }

  Future<void> retryTor() async {
    state = state.copyWith(
      error: '',
      notice: 'Ponawianie połączenia transportowego…',
    );
    try {
      await _repository.connect();
      await refreshData();
    } catch (error) {
      state = state.copyWith(error: _message(error), notice: '');
    }
  }

  Future<void> setNickname(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        profile: profile,
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
          peerServerStatus: state.peerServerStatus,
        ),
        error: '',
      );
      unawaited(_maybeAutoPairTorka());
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
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool('torchat.privacy.readReceipts') ?? true) {
        await _repository.sendReadReceipts(id);
      }
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

  Future<void> sendMessage(String text, {String? replyToMessageId}) async {
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
        messages: await _repository.messages(id),
        action: '',
        notice: '',
      );
    } catch (error) {
      state = state.copyWith(action: '', error: _message(error));
    }
  }

  Future<void> retryMessage(String messageId) async {
    try {
      await _repository.retryMessage(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        state = state.copyWith(
          messages: await _repository.messages(conversationId),
          error: '',
        );
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> deleteMessageLocal(String messageId) async {
    try {
      await _repository.deleteMessageLocal(messageId);
      final conversationId = state.selectedConversationId;
      if (conversationId != null) {
        state = state.copyWith(
          messages: await _repository.messages(conversationId),
          error: '',
        );
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> setTyping(bool typing) async {
    final conversationId = state.selectedConversationId;
    if (conversationId == null) return;
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('torchat.privacy.typing') ?? true)) return;
    try {
      await _repository.setTyping(conversationId, typing);
    } catch (_) {}
  }

  Future<void> updateVisibility(bool foreground) async {
    await _repository.updateAppVisibility(foreground);
    final preferences = await SharedPreferences.getInstance();
    final enabled = preferences.getBool('torchat.privacy.presence') ?? true;
    try {
      await _repository.setPresence(foreground && enabled);
    } catch (_) {}
  }

  Future<void> submitPairingCode(String code) async {
    if (!state.transport.connected) {
      state = state.copyWith(
        error: 'Poczekaj na zielony pasek połączenia Tor.',
        notice: '',
      );
      return;
    }
    if (state.profile.nickname.trim().length < 2) {
      state = state.copyWith(
        error: 'Najpierw ustaw nazwę użytkownika na tym urządzeniu.',
        notice: '',
      );
      return;
    }
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
      await _cancelBlockingTorkaOutboxIfNeeded(normalizedCode);
      final item = await _repository.submitPairingCode(normalizedCode);
      final hintedInstallationId = item.peer?.id.trim() ?? '';
      if (hintedInstallationId.isNotEmpty) {
        _torkaInstallationIdHint = hintedInstallationId;
      }
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

  Future<void> updateContactSettings(
    ContactRecord contact,
    String? localAlias,
    bool muted,
    bool blocked,
    ContactTransportPolicy transportPolicy,
  ) async {
    try {
      await _repository.updateContactSettings(
        contact.id,
        localAlias: localAlias,
        muted: muted,
        blocked: blocked,
        transportPolicy: transportPolicy,
      );
      state = state.copyWith(contacts: await _repository.contacts(), error: '');
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
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
    }
    return error.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
  }

  bool get _devTorkaEnabled => false;
  Future<void> _cancelBlockingTorkaOutboxIfNeeded(String code) async {}
  Future<void> _maybeAutoPairTorka() async {}
  void _stopTorkaWatchdog() {}

  void _handleEvent(RuntimeEvent event) {}

  List<StartupStep> _startupSteps(
    List<StartupStep> current,
    StartupStepKind kind,
    StartupStepState stepState,
    String detail,
  ) => transitionStartupStep(current, kind, stepState, detail);

  List<StartupStep> _startupStepsForEndpoint(
    List<StartupStep> current,
    bool available, {
    required bool torReady,
    required bool relayReady,
    required PeerServerStatus peerServerStatus,
  }) {
    var steps = current;
    if (available) {
      steps = _startupSteps(steps, StartupStepKind.peerListener, StartupStepState.ready, 'Lokalny listener działa');
      steps = _startupSteps(steps, StartupStepKind.onionService, StartupStepState.ready, 'Adres onion jest dostępny');
      steps = _startupSteps(steps, StartupStepKind.communication, relayReady ? StartupStepState.ready : StartupStepState.pending, relayReady ? 'Komunikacja jest gotowa' : 'Oczekiwanie na relay');
    }
    return steps;
  }

  ControllerScreen _screenAfterConnect(
    RuntimeProfile profile,
    RuntimeTorStatus transport, {
    List<StartupStep>? startupSteps,
    PeerServerStatus? peerServerStatus,
  }) {
    if (profile.nickname.trim().isNotEmpty) return ControllerScreen.main;
    final steps = startupSteps ?? state.startupSteps;
    final ready = transport.connected &&
        (peerServerStatus ?? state.peerServerStatus) == PeerServerStatus.ready &&
        steps.every((step) => step.state == StartupStepState.ready);
    return ready ? ControllerScreen.nickname : ControllerScreen.boot;
  }

  PeerServerStatus _peerServerStatusForRefresh(
    RuntimeTorStatus transport,
    bool peerEndpointAvailable, {
    required PeerServerStatus current,
  }) {
    if (peerEndpointAvailable) return PeerServerStatus.ready;
    if (transport.failed) return PeerServerStatus.error;
    return current == PeerServerStatus.error ? current : PeerServerStatus.starting;
  }

  List<ContactRecord> _mergeRefreshedContacts(List<ContactRecord> refreshed) => refreshed;
}
