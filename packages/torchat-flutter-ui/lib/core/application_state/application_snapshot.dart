import '../models/domain.dart';

const Object _snapshotSentinel = Object();

class ProjectionStamp {
  const ProjectionStamp({
    this.storeId = '',
    this.engineSessionId = '',
    this.revision = 0,
  });

  final String storeId;
  final String engineSessionId;
  final int revision;
}

class ConversationProjection {
  const ConversationProjection({
    required this.stamp,
    required this.conversationId,
    required this.messages,
    this.hasMore = false,
  });

  final ProjectionStamp stamp;
  final String conversationId;
  final List<ChatMessage> messages;
  final bool hasMore;
}

class ApplicationSnapshot {
  const ApplicationSnapshot({
    this.schemaVersion = 1,
    this.generation = 0,
    this.createdAtMs = 0,
    this.identity = const RuntimeIdentity(),
    this.profile = const RuntimeProfile(),
    this.contacts = const [],
    this.conversations = const [],
    this.pendingInbox = 0,
    this.pendingOutbox = 0,
    this.peerEndpointAvailable = false,
    this.projectionStoreId = '',
    this.projectionSessionId = '',
    this.projectionRevision = 0,
    this.destination = 'chats',
    this.selectedConversationId,
  });

  final int schemaVersion;
  final int generation;
  final int createdAtMs;
  final RuntimeIdentity identity;
  final RuntimeProfile profile;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final int pendingInbox;
  final int pendingOutbox;
  final bool peerEndpointAvailable;
  final String projectionStoreId;
  final String projectionSessionId;
  final int projectionRevision;

  ProjectionStamp get projection => ProjectionStamp(
    storeId: projectionStoreId,
    engineSessionId: projectionSessionId,
    revision: projectionRevision,
  );
  final String destination;
  final String? selectedConversationId;

  bool get hasProfile => profile.nickname.trim().length >= 2;

  ApplicationSnapshot copyWith({
    int? schemaVersion,
    int? generation,
    int? createdAtMs,
    RuntimeIdentity? identity,
    RuntimeProfile? profile,
    List<ContactRecord>? contacts,
    List<ConversationSummary>? conversations,
    int? pendingInbox,
    int? pendingOutbox,
    bool? peerEndpointAvailable,
    String? projectionStoreId,
    String? projectionSessionId,
    int? projectionRevision,
    String? destination,
    Object? selectedConversationId = _snapshotSentinel,
  }) => ApplicationSnapshot(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    generation: generation ?? this.generation,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    identity: identity ?? this.identity,
    profile: profile ?? this.profile,
    contacts: contacts ?? this.contacts,
    conversations: conversations ?? this.conversations,
    pendingInbox: pendingInbox ?? this.pendingInbox,
    pendingOutbox: pendingOutbox ?? this.pendingOutbox,
    peerEndpointAvailable: peerEndpointAvailable ?? this.peerEndpointAvailable,
    projectionStoreId: projectionStoreId ?? this.projectionStoreId,
    projectionSessionId: projectionSessionId ?? this.projectionSessionId,
    projectionRevision: projectionRevision ?? this.projectionRevision,
    destination: destination ?? this.destination,
    selectedConversationId: identical(selectedConversationId, _snapshotSentinel)
        ? this.selectedConversationId
        : selectedConversationId as String?,
  );
}
