import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

import '../client_runtime.dart';
import '../core/application_state/application_state_store.dart';
import '../locales/domain/user_problem.dart';

enum ControllerScreen { boot, nickname, main }

enum MainDestination { chats, contacts, account, settings, tor }

class AppState {
  const AppState({
    this.screen = ControllerScreen.boot,
    this.destination = MainDestination.chats,
    this.ownInvite,
    this.transport = const RuntimeTorStatus(),
    this.peerServerStatus = PeerServerStatus.starting,
    this.transportStatuses = const {},
    this.startupSteps = const [],
    this.selectedConversationId,
    this.isLoading = false,
    this.action = '',
    this.error = '',
    this.problem,
    this.typingContacts = const {},
    this.lastSeenEnabled = true,
    this.applicationSnapshot,
  });

  final ControllerScreen screen;
  final MainDestination destination;
  final ApplicationSnapshot? applicationSnapshot;

  RuntimeIdentity get identity =>
      applicationSnapshot?.identity ?? const RuntimeIdentity();
  RuntimeProfile get profile =>
      applicationSnapshot?.profile ?? const RuntimeProfile();
  List<ContactRecord> get contacts => applicationSnapshot?.contacts ?? const [];
  List<ConversationSummary> get conversations =>
      applicationSnapshot?.conversations ?? const [];
  List<PairingItem> get inbox =>
      applicationSnapshot?.pairingInbox ?? const <PairingItem>[];
  List<PairingItem> get outbox =>
      applicationSnapshot?.pairingOutbox ?? const <PairingItem>[];
  List<ChatMessage> get messages =>
      ApplicationStateStore.shared.messages(selectedConversationId ?? '');

  final InviteCode? ownInvite;
  final RuntimeTorStatus transport;
  final PeerServerStatus peerServerStatus;
  final Map<TransportComponent, TransportStatusSnapshot> transportStatuses;
  final List<StartupStep> startupSteps;
  final String? selectedConversationId;
  final bool isLoading;
  final String action;
  final String error;
  final UserProblem? problem;
  final Map<String, bool> typingContacts;
  final bool lastSeenEnabled;

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
    InviteCode? ownInvite,
    RuntimeTorStatus? transport,
    PeerServerStatus? peerServerStatus,
    Map<TransportComponent, TransportStatusSnapshot>? transportStatuses,
    List<StartupStep>? startupSteps,
    String? selectedConversationId,
    bool clearSelection = false,
    bool? isLoading,
    String? action,
    String? error,
    UserProblem? problem,
    bool clearProblem = false,
    Map<String, bool>? typingContacts,
    bool? lastSeenEnabled,
    ApplicationSnapshot? applicationSnapshot,
  }) => AppState(
    screen: screen ?? this.screen,
    destination: destination ?? this.destination,
    ownInvite: ownInvite ?? this.ownInvite,
    transport: transport ?? this.transport,
    peerServerStatus: peerServerStatus ?? this.peerServerStatus,
    transportStatuses: transportStatuses ?? this.transportStatuses,
    startupSteps: startupSteps ?? this.startupSteps,
    selectedConversationId: clearSelection
        ? null
        : selectedConversationId ?? this.selectedConversationId,
    isLoading: isLoading ?? this.isLoading,
    action: action ?? this.action,
    error: error ?? this.error,
    problem:
        problem ??
        (clearProblem || (error != null && error.isEmpty)
            ? null
            : this.problem),
    typingContacts: typingContacts ?? this.typingContacts,
    lastSeenEnabled: lastSeenEnabled ?? this.lastSeenEnabled,
    applicationSnapshot: applicationSnapshot ?? this.applicationSnapshot,
  );
}
