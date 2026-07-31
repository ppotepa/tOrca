import '../models/domain.dart';
import 'application_snapshot.dart';

class ApplicationSnapshotPatch {
  const ApplicationSnapshotPatch({
    required this.baseGeneration,
    required this.generation,
    required this.createdAtMs,
    this.identity,
    this.profile,
    this.contacts,
    this.conversations,
    this.pendingInbox,
    this.pendingOutbox,
    this.peerEndpointAvailable,
  });

  final int baseGeneration;
  final int generation;
  final int createdAtMs;
  final RuntimeIdentity? identity;
  final RuntimeProfile? profile;
  final List<ContactRecord>? contacts;
  final List<ConversationSummary>? conversations;
  final int? pendingInbox;
  final int? pendingOutbox;
  final bool? peerEndpointAvailable;

  bool canApplyTo(ApplicationSnapshot snapshot) =>
      snapshot.generation == baseGeneration && generation > baseGeneration;

  ApplicationSnapshot applyTo(ApplicationSnapshot snapshot) {
    if (!canApplyTo(snapshot)) {
      throw StateError(
        'Snapshot patch generation mismatch: '
        'current=${snapshot.generation} base=$baseGeneration next=$generation',
      );
    }
    return snapshot.copyWith(
      generation: generation,
      createdAtMs: createdAtMs,
      identity: identity,
      profile: profile,
      contacts: contacts == null ? null : List.unmodifiable(contacts!),
      conversations:
          conversations == null ? null : List.unmodifiable(conversations!),
      pendingInbox: pendingInbox,
      pendingOutbox: pendingOutbox,
      peerEndpointAvailable: peerEndpointAvailable,
    );
  }

  factory ApplicationSnapshotPatch.replace(
    ApplicationSnapshot current,
    ApplicationSnapshot next,
  ) => ApplicationSnapshotPatch(
    baseGeneration: current.generation,
    generation: next.generation,
    createdAtMs: next.createdAtMs,
    identity: next.identity,
    profile: next.profile,
    contacts: next.contacts,
    conversations: next.conversations,
    pendingInbox: next.pendingInbox,
    pendingOutbox: next.pendingOutbox,
    peerEndpointAvailable: next.peerEndpointAvailable,
  );
}
