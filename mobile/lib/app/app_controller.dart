import 'dart:async';
import 'dart:io';

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
  final Map<String, Timer> _typingExpiry = {};

  @override
  AppState build() {
    _repository = ref.watch(runtimeRepositoryProvider);
    ref.onDispose(() {
      _events?.cancel();
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
      await refreshData();
      state = state.copyWith(
        identity: identity,
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
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

  Future<void> refreshData() async {
    final contacts = _mergeRefreshedContacts(await _repository.contacts());
    final conversations = await _repository.conversations();
    final inbox = await _repository.inbox();
    final outbox = await _repository.outbox();
    final peerEndpointAvailable = await _repository.peerEndpointAvailable();
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
        peerServerStatus: peerServerStatus,
      ),
    );
    if (state.transport.connected) {
      state = state.copyWith(
        screen: _screenAfterConnect(
          state.profile,
          state.transport,
          startupSteps: state.startupSteps,
        ),
      );
    }
  }

  Future<void> retryTor() => initialize();

  Future<void> setNickname(String nickname) async {
    try {
      final profile = await _repository.setNickname(nickname.trim());
      state = state.copyWith(
        profile: profile,
        screen: _screenAfterConnect(
          profile,
          state.transport,
          startupSteps: state.startupSteps,
        ),
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
    } catch (_) {
      // Typing is ephemeral and must not replace a useful chat error.
    }
  }

  Future<void> updateVisibility(bool foreground) async {
    await _repository.updateAppVisibility(foreground);
    final preferences = await SharedPreferences.getInstance();
    final enabled = preferences.getBool('torchat.privacy.presence') ?? true;
    try {
      await _repository.setPresence(foreground && enabled);
    } catch (_) {
      // Presence is best-effort and never blocks lifecycle changes.
    }
  }

  Future<void> submitPairingCode(String code) async {
    if (!state.transport.connected) {
      state = state.copyWith(
        error: 'Poczekaj na zielony pasek połączenia Tor.',
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
      if (message != null && message.isNotEmpty) {
        return _localizedRuntimeError(message);
      }
      return switch (error.code) {
        'RUNTIME' =>
          'Operacja nie jest jeszcze dostępna. Poczekaj na połączenie z relayem.',
        _ => 'Operacja nie powiodła się (${error.code}).',
      };
    }
    return _localizedRuntimeError(
      error
          .toString()
          .replaceFirst('Exception: ', '')
          .replaceFirst('Bad state: ', ''),
    );
  }

  String _localizedRuntimeError(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('pairing code expired or invalid')) {
      return 'Kod parowania jest nieprawidłowy albo wygasł. Poproś kontakt o nowy kod.';
    }
    if (normalized.contains('cannot pair with yourself')) {
      return 'Nie możesz dodać własnego kodu parowania.';
    }
    if (normalized.contains(
      'a pending invitation to this user already exists',
    )) {
      return 'Zaproszenie do tego kontaktu już oczekuje.';
    }
    if (normalized.contains('too many pairing attempts')) {
      return 'Zbyt wiele prób parowania. Poczekaj chwilę i spróbuj ponownie.';
    }
    if (normalized.contains('pairing request not found')) {
      return 'To zaproszenie wygasło albo zostało już obsłużone.';
    }
    if (normalized.contains('invalid welcome signature') ||
        normalized.contains('identity') &&
            normalized.contains('does not match') ||
        normalized.contains('signature is invalid')) {
      return 'Nie udało się potwierdzić tożsamości drugiej strony. Zaproszenie zostało odrzucone.';
    }
    if (normalized.contains('peer endpoint') &&
        normalized.contains('missing')) {
      return 'Kontakt nie przekazał jeszcze zweryfikowanego endpointu P2P.';
    }
    if (normalized.contains('peer endpoint') &&
        (normalized.contains('invalid') ||
            normalized.contains('expired') ||
            normalized.contains('stale'))) {
      return 'Endpoint P2P kontaktu jest nieprawidłowy albo wygasł.';
    }
    if (normalized.contains('contact') &&
        (normalized.contains('already exists') ||
            normalized.contains('already a contact'))) {
      return 'Ten kontakt już istnieje.';
    }
    if (normalized.contains('acknowledgement') &&
        (normalized.contains('missing') ||
            normalized.contains('timed out'))) {
      return 'Brak potwierdzenia drugiej strony. Spróbuj ponownie po odzyskaniu połączenia.';
    }
    if (normalized.contains('relay transport error')) {
      return 'Relay onion jest chwilowo niedostępny. Spróbuj ponownie za chwilę.';
    }
    return message;
  }

  void _handleEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeReadyEvent():
        state = state.copyWith(
          peerServerStatus: PeerServerStatus.starting,
          startupSteps: _startupSteps(
            _startupSteps(
              state.startupSteps,
              StartupStepKind.engine,
              StartupStepState.ready,
              'Engine działa',
            ),
            StartupStepKind.tor,
            StartupStepState.running,
            'Oczekiwanie na gotowość Tor',
          ),
        );
      case TorStatusEvent(:final snapshot):
        final becameConnected =
            !state.transport.connected && snapshot.connected;
        final startupSteps = _startupStepsForTor(
          state.startupSteps,
          snapshot,
        );
        state = state.copyWith(
          transport: snapshot,
          error: snapshot.phase.isError ? state.error : '',
          screen: _screenAfterConnect(
            state.profile,
            snapshot,
            startupSteps: startupSteps,
          ),
          startupSteps: startupSteps,
        );
        if (snapshot.phase == TransportPhase.connecting ||
            snapshot.phase == TransportPhase.connected) {
          unawaited(_refreshAfterEvent());
        }
        if (becameConnected && !_introPlayed) {
          _introPlayed = true;
          unawaited(_playIntro());
        }
      case ProfileReadyEvent(:final profile):
        final nextProfile =
            profile.nickname.trim().isEmpty &&
                state.profile.nickname.trim().isNotEmpty
            ? state.profile
            : profile;
        state = state.copyWith(
          profile: nextProfile,
          error: '',
          screen: _screenAfterConnect(
            nextProfile,
            state.transport,
            startupSteps: state.startupSteps,
          ),
          startupSteps: _startupSteps(
            state.startupSteps,
            StartupStepKind.engine,
            StartupStepState.ready,
            'Tożsamość i profil są gotowe',
          ),
        );
      case DataChangedEvent(:final type, :final payload):
        if (type == EngineContract.typingChanged) {
          _applyTypingEvent(payload);
        } else if (type == EngineContract.presenceChanged) {
          final contactId = payload[EngineContract.contactId]?.toString();
          if (contactId != null && contactId.isNotEmpty) {
            state = state.copyWith(
              onlineContacts: {
                ...state.onlineContacts,
                contactId: payload[EngineContract.online] == true,
              },
            );
          }
        } else {
          unawaited(_refreshAfterEvent());
        }
      case PeerEndpointChangedEvent(:final contactId, :final status):
        if (contactId == state.identity.installationId && contactId.isNotEmpty) {
          final peerReady = status == PeerEndpointStatus.verified;
          final peerServerStatus = peerReady
              ? PeerServerStatus.ready
              : PeerServerStatus.offline;
          state = state.copyWith(
            peerServerStatus: peerServerStatus,
            error: peerReady ? '' : state.error,
            startupSteps: _startupStepsForEndpoint(
              state.startupSteps,
              peerReady,
              torReady: state.transport.usable,
              peerServerStatus: peerServerStatus,
            ),
          );
        }
        unawaited(_refreshAfterEvent());
      case PeerConnectionChangedEvent(:final contactId, :final status):
        final updatedContacts = [
          for (final contact in state.contacts)
            if (contact.id == contactId)
              contact.copyWith(peerConnectionStatus: status)
            else
              contact,
        ];
        state = state.copyWith(contacts: updatedContacts);
        break;
      case RuntimeErrorEvent(:final message):
        state = state.copyWith(
          error: message,
          startupSteps: _markStartupError(state.startupSteps, message),
        );
      case RuntimeLogEvent(:final message):
        if (message.toLowerCase().contains('onion service unavailable')) {
          final startupSteps = _startupSteps(
            _startupSteps(
              _startupSteps(
                state.startupSteps,
                StartupStepKind.communication,
                StartupStepState.warning,
                'Endpoint P2P jest wymagany do gotowości',
              ),
              StartupStepKind.peerListener,
              StartupStepState.ready,
              'Lokalny listener działa',
            ),
            StartupStepKind.onionService,
            StartupStepState.error,
            message,
          );
          state = state.copyWith(
            peerServerStatus: PeerServerStatus.offline,
            error: message,
            screen: _screenAfterConnect(
              state.profile,
              state.transport,
              startupSteps: startupSteps,
            ),
            startupSteps: startupSteps,
          );
        }
        // Diagnostics are not a data mutation and must not trigger network
        // refreshes while the onion connection is warming up.
        break;
      case NotificationRequestedEvent():
        unawaited(_pagerBeep());
    }
  }

  List<StartupStep> _startupSteps(
    List<StartupStep> current,
    StartupStepKind kind,
    StartupStepState stepState,
    String detail,
  ) {
    return transitionStartupStep(current, kind, stepState, detail);
  }

  List<StartupStep> _startupStepsForTor(
    List<StartupStep> current,
    RuntimeTorStatus snapshot,
  ) {
    final torState = switch (snapshot.phase) {
      TransportPhase.starting || TransportPhase.bootstrapping =>
        StartupStepState.running,
      TransportPhase.connecting || TransportPhase.connected =>
        StartupStepState.ready,
      TransportPhase.reconnecting || TransportPhase.degraded =>
        StartupStepState.warning,
      TransportPhase.offline => StartupStepState.warning,
      TransportPhase.error => StartupStepState.error,
    };
    var steps = _startupSteps(
      current,
      StartupStepKind.tor,
      torState,
      snapshot.detail.isEmpty ? snapshot.label : snapshot.detail,
    );
    if (snapshot.phase.isConnected) {
      steps = _startupSteps(
        steps,
        StartupStepKind.peerListener,
        StartupStepState.running,
        'Sprawdzanie lokalnego listenera',
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.onionService,
        StartupStepState.running,
        'Oczekiwanie na adres onion',
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.relay,
        StartupStepState.ready,
        snapshot.detail.isEmpty ? 'Relay połączony' : snapshot.detail,
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.communication,
        StartupStepState.running,
        'Można wysyłać i odbierać wiadomości',
      );
    } else if (snapshot.phase.isConnecting || snapshot.phase.isWarning) {
      steps = _startupSteps(
        steps,
        StartupStepKind.peerListener,
        StartupStepState.running,
        'Uruchamianie lokalnego listenera',
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.onionService,
        StartupStepState.running,
        'Publikowanie usługi onion',
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.relay,
        StartupStepState.running,
        snapshot.detail.isEmpty ? 'Łączenie z relayem' : snapshot.detail,
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.communication,
        StartupStepState.pending,
        'Oczekiwanie na gotowość relay',
      );
    } else if (snapshot.phase.isError) {
      steps = _startupSteps(
        steps,
        StartupStepKind.relay,
        StartupStepState.error,
        snapshot.detail,
      );
    }
    if (!snapshot.phase.isConnected) {
      steps = _startupSteps(
        steps,
        StartupStepKind.peerListener,
        StartupStepState.pending,
        'Oczekiwanie na gotowość Tor',
      );
      steps = _startupSteps(
        steps,
        StartupStepKind.onionService,
        StartupStepState.pending,
        'Oczekiwanie na gotowość Tor',
      );
    }
    return steps;
  }

  List<StartupStep> _startupStepsForEndpoint(
    List<StartupStep> current,
    bool available, {
    required bool torReady,
    required PeerServerStatus peerServerStatus,
  }) {
    if (!torReady) return current;
    if (!available) {
      final failed =
          peerServerStatus == PeerServerStatus.offline ||
          peerServerStatus == PeerServerStatus.error;
      var waiting = _startupSteps(
        current,
        StartupStepKind.peerListener,
        failed ? StartupStepState.error : StartupStepState.running,
        failed
            ? 'Lokalny listener P2P nie jest gotowy'
            : 'Oczekiwanie na lokalny endpoint P2P',
      );
      waiting = _startupSteps(
        waiting,
        StartupStepKind.onionService,
        failed ? StartupStepState.error : StartupStepState.running,
        failed
            ? 'Usługa onion P2P nie jest dostępna'
            : 'Oczekiwanie na adres onion P2P',
      );
      return _startupSteps(
        waiting,
        StartupStepKind.communication,
        failed ? StartupStepState.error : StartupStepState.pending,
        failed
            ? 'Komunikacja nie jest gotowa bez endpointu P2P'
            : 'Oczekiwanie na endpoint P2P',
      );
    }
    var steps = _startupSteps(
      current,
      StartupStepKind.peerListener,
      StartupStepState.ready,
      'Lokalny listener działa',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.onionService,
      StartupStepState.ready,
      'Adres onion jest dostępny',
    );
    steps = _startupSteps(
      steps,
      StartupStepKind.communication,
      StartupStepState.ready,
      'Komunikacja jest gotowa',
    );
    return steps;
  }

  List<StartupStep> _markStartupError(
    List<StartupStep> current,
    String message,
  ) {
    final steps = current.isEmpty ? initialStartupSteps() : current;
    final active = steps.indexWhere(
      (step) =>
          step.state == StartupStepState.running ||
          step.state == StartupStepState.warning,
    );
    if (active < 0) return steps;
    return [
      for (var index = 0; index < steps.length; index += 1)
        index == active
            ? steps[index].copyWith(state: StartupStepState.error, detail: message)
            : index > active
            ? steps[index].copyWith(
                state: StartupStepState.blocked,
                detail: 'Zablokowano przez wcześniejszy błąd',
              )
            : steps[index],
    ];
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

  void _applyTypingEvent(Map<String, dynamic> payload) {
    final conversationId = payload[EngineContract.conversationId]?.toString();
    if (conversationId == null || conversationId.isEmpty) return;
    final typing = payload[EngineContract.typing] == true;
    _typingExpiry.remove(conversationId)?.cancel();
    state = state.copyWith(
      typingContacts: {...state.typingContacts, conversationId: typing},
    );
    if (typing) {
      _typingExpiry[conversationId] = Timer(const Duration(seconds: 5), () {
        state = state.copyWith(
          typingContacts: {...state.typingContacts, conversationId: false},
        );
        _typingExpiry.remove(conversationId);
      });
    }
  }

  ControllerScreen _screenAfterConnect(
    RuntimeProfile profile,
    RuntimeTorStatus transport, {
    List<StartupStep>? startupSteps,
  }) {
    if (!transport.connected) return ControllerScreen.boot;
    if (startupSteps != null && !_startupAllowsContinue(startupSteps)) {
      return ControllerScreen.boot;
    }
    if (profile.nickname.trim().isNotEmpty) return ControllerScreen.main;
    return ControllerScreen.nickname;
  }

  bool _startupAllowsContinue(List<StartupStep> steps) {
    return StartupStepKind.values.every(
      (kind) => steps.any(
        (step) =>
            step.kind == kind && step.state == StartupStepState.ready,
      ),
    );
  }

  PeerServerStatus _peerServerStatusForRefresh(
    RuntimeTorStatus transport,
    bool peerEndpointAvailable, {
    required PeerServerStatus current,
  }) {
    if (transport.failed) {
      return PeerServerStatus.error;
    }
    if (!transport.usable) {
      return PeerServerStatus.starting;
    }
    if (peerEndpointAvailable) {
      return PeerServerStatus.ready;
    }
    if (current == PeerServerStatus.offline || current == PeerServerStatus.error) {
      return current;
    }
    return PeerServerStatus.starting;
  }

  List<ContactRecord> _mergeRefreshedContacts(List<ContactRecord> refreshed) {
    if (state.contacts.isEmpty) return refreshed;
    final currentById = {
      for (final contact in state.contacts) contact.id: contact,
    };
    return [
      for (final contact in refreshed)
        _mergeRefreshedContact(contact, currentById[contact.id]),
    ];
  }

  ContactRecord _mergeRefreshedContact(
    ContactRecord refreshed,
    ContactRecord? current,
  ) {
    if (current == null) return refreshed;
    final preserveTransientPeerStatus =
        refreshed.peerConnectionStatus == PeerConnectionStatus.offline &&
        current.peerConnectionStatus != PeerConnectionStatus.offline;
    final lastPeerConnectedAt =
        refreshed.lastPeerConnectedAt ?? current.lastPeerConnectedAt;
    return refreshed.copyWith(
      peerConnectionStatus: preserveTransientPeerStatus
          ? current.peerConnectionStatus
          : refreshed.peerConnectionStatus,
      lastPeerConnectedAt: lastPeerConnectedAt,
    );
  }

  Future<void> _pagerBeep() async {
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('torchat.notifications.enabled') ?? true) ||
        !(preferences.getBool('torchat.notifications.sound') ?? true)) {
      return;
    }
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

  Future<void> _playIntro() async {
    try {
      const channel = MethodChannel('org.torchat/audio');
      await channel.invokeMethod<void>('playIntro');
    } on MissingPluginException {
      // Widget tests and unsupported platforms do not register native audio.
    } on PlatformException {
      // Audio is optional and must never turn a successful Tor connection
      // into an application error.
    }
  }
}
