import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/relationships/relationship_message.dart';

void main() {
  test('relationship removal message round-trips', () {
    final removedAt = DateTime.utc(2026, 7, 31, 18, 30);
    final encoded = RelationshipRemovedMessage(
      removedAt: removedAt,
      preserveHistory: true,
    ).encode();

    final decoded = RelationshipRemovedMessage.tryDecode(encoded);

    expect(decoded, isNotNull);
    expect(decoded!.removedAt, removedAt);
    expect(decoded.preserveHistory, isTrue);
    expect(isRelationshipRemovedMessage(encoded), isTrue);
  });

  test('relationship removal can request local history deletion', () {
    final encoded = RelationshipRemovedMessage(
      removedAt: DateTime.utc(2026, 7, 31),
      preserveHistory: false,
    ).encode();

    expect(
      RelationshipRemovedMessage.tryDecode(encoded)!.preserveHistory,
      isFalse,
    );
  });

  test('ordinary and malformed messages are ignored', () {
    expect(RelationshipRemovedMessage.tryDecode('hello'), isNull);
    expect(
      RelationshipRemovedMessage.tryDecode('${relationshipRemovedPrefix}{}'),
      isNull,
    );
    expect(
      RelationshipRemovedMessage.tryDecode('${relationshipRemovedPrefix}{broken'),
      isNull,
    );
  });
}
