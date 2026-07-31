import '../models/domain.dart';

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
    peerEndpointAvailable:
        peerEndpointAvailable ?? this.peerEndpointAvailable,
  );
}
