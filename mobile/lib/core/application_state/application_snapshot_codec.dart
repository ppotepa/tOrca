import '../models/domain.dart';
import 'application_snapshot.dart';
import 'application_state_store.dart';

ApplicationSnapshot? parseApplicationSnapshotMap(Map<String, dynamic> raw) {
  final identityMap = _map(raw['identity']);
  final profileMap = _map(raw['profile']);
  if (identityMap == null || profileMap == null) return null;

  final identity = RuntimeIdentity.fromMap(identityMap);
  final profile = RuntimeProfile.fromMap(profileMap);
  final contacts = _mapList(raw['contacts'])
      .map(ContactRecord.fromMap)
      .toList(growable: false);
  final conversations = _mapList(raw['conversations'])
      .map(ConversationSummary.fromMap)
      .toList(growable: false);
  final now = DateTime.now();
  final rawGeneration = _intValue(raw['generation']);
  final rawCreatedAt = _intValue(raw['createdAtMs']);

  return ApplicationSnapshot(
    generation:
        rawGeneration == 0 ? now.microsecondsSinceEpoch : rawGeneration,
    createdAtMs: rawCreatedAt == 0 ? now.millisecondsSinceEpoch : rawCreatedAt,
    identity: identity,
    profile: profile,
    contacts: List.unmodifiable(contacts),
    conversations: List.unmodifiable(conversations),
    pendingInbox: _intValue(raw['pendingInbox']),
    pendingOutbox: _intValue(raw['pendingOutbox']),
    peerEndpointAvailable: raw['peerEndpointAvailable'] == true,
  );
}

bool hydrateApplicationSnapshotMap(
  Map<String, dynamic> raw, {
  ApplicationStateStore? store,
}) {
  final snapshot = parseApplicationSnapshotMap(raw);
  if (snapshot == null) return false;
  final target = store ?? ApplicationStateStore.shared;
  final current = target.current;
  if (current != null &&
      current.identity.installationId.isNotEmpty &&
      snapshot.identity.installationId.isNotEmpty &&
      current.identity.installationId != snapshot.identity.installationId) {
    target.clear();
  }
  return target.hydrate(snapshot);
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> _mapList(Object? value) =>
    (value as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
