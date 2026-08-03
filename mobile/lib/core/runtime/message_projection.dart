import '../../client_runtime.dart';

/// Stable ordering shared by initial loads, paging and live message events.
int compareMessages(ChatMessage left, ChatMessage right) {
  final leftAt = DateTime.tryParse(left.createdAt)?.millisecondsSinceEpoch ?? 0;
  final rightAt =
      DateTime.tryParse(right.createdAt)?.millisecondsSinceEpoch ?? 0;
  final time = leftAt.compareTo(rightAt);
  return time != 0 ? time : left.id.compareTo(right.id);
}
