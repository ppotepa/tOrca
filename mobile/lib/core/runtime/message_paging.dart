import '../../client_runtime.dart';
import '../models/domain.dart';

const _messagePagePrefix = 'torchat-page-v1\t';
const _messageAllPrefix = 'torchat-all-v1\t';
const defaultMessagePageSize = 50;

class RuntimeMessagePage {
  const RuntimeMessagePage({
    required this.messages,
    required this.hasMore,
  });

  final List<ChatMessage> messages;
  final bool hasMore;
}

extension ClientRuntimeMessagePaging on ClientRuntime {
  Future<RuntimeMessagePage> messagePage(
    String conversationId, {
    ChatMessage? before,
    int limit = defaultMessagePageSize,
  }) async {
    final id = _validatedConversationId(conversationId);
    final pageSize = limit.clamp(1, 200).toInt();
    final beforeAt = before == null
        ? ''
        : (DateTime.tryParse(before.createdAt)
                  ?.toUtc()
                  .millisecondsSinceEpoch ??
              0)
            .toString();
    final beforeId = before?.id ?? '';
    final encoded = '$_messagePagePrefix$id\t$pageSize\t$beforeAt\t$beforeId';

    try {
      final result = await messages(encoded);
      if (result.isNotEmpty || before == null) {
        return RuntimeMessagePage(
          messages: result,
          hasMore: result.length == pageSize,
        );
      }
    } catch (_) {
      // Older and fixture runtimes do not understand cursor identifiers.
    }

    final all = await messages(id);
    final filtered = before == null
        ? List<ChatMessage>.of(all)
        : all.where((message) => _isBefore(message, before)).toList();
    filtered.sort(_compareMessages);
    final start = filtered.length > pageSize ? filtered.length - pageSize : 0;
    final page = filtered.sublist(start);
    return RuntimeMessagePage(
      messages: page,
      hasMore: start > 0 || page.length == pageSize,
    );
  }

  Future<List<ChatMessage>> allMessages(String conversationId) async {
    final id = _validatedConversationId(conversationId);
    try {
      final result = await messages('$_messageAllPrefix$id');
      if (result.isNotEmpty) return result;
    } catch (_) {
      // Fall back to the legacy full-list contract.
    }
    return messages(id);
  }
}

String _validatedConversationId(String value) {
  final id = value.trim();
  if (id.isEmpty || id.contains('\t')) {
    throw ArgumentError.value(value, 'conversationId', 'Invalid conversation ID');
  }
  return id;
}

bool _isBefore(ChatMessage candidate, ChatMessage cursor) {
  final candidateAt =
      DateTime.tryParse(candidate.createdAt)?.millisecondsSinceEpoch ?? 0;
  final cursorAt = DateTime.tryParse(cursor.createdAt)?.millisecondsSinceEpoch ?? 0;
  return candidateAt < cursorAt ||
      (candidateAt == cursorAt && candidate.id.compareTo(cursor.id) < 0);
}

int _compareMessages(ChatMessage left, ChatMessage right) {
  final leftAt = DateTime.tryParse(left.createdAt)?.millisecondsSinceEpoch ?? 0;
  final rightAt = DateTime.tryParse(right.createdAt)?.millisecondsSinceEpoch ?? 0;
  final time = leftAt.compareTo(rightAt);
  return time != 0 ? time : left.id.compareTo(right.id);
}
