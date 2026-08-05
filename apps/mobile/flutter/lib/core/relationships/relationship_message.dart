import 'dart:convert';

const relationshipRemovedPrefix = 'torchat-relationship-removed-v1:';

class RelationshipRemovedMessage {
  const RelationshipRemovedMessage({
    required this.removedAt,
    required this.preserveHistory,
  });

  final DateTime removedAt;
  final bool preserveHistory;

  String encode() =>
      '$relationshipRemovedPrefix${jsonEncode({'removedAt': removedAt.toUtc().toIso8601String(), 'preserveHistory': preserveHistory})}';

  static RelationshipRemovedMessage? tryDecode(String body) {
    if (!body.startsWith(relationshipRemovedPrefix)) return null;
    try {
      final value = jsonDecode(
        body.substring(relationshipRemovedPrefix.length),
      );
      if (value is! Map) return null;
      final removedAt = DateTime.tryParse(value['removedAt']?.toString() ?? '');
      if (removedAt == null) return null;
      return RelationshipRemovedMessage(
        removedAt: removedAt,
        preserveHistory: value['preserveHistory'] != false,
      );
    } catch (_) {
      return null;
    }
  }
}

bool isRelationshipRemovedMessage(String body) =>
    RelationshipRemovedMessage.tryDecode(body) != null;
