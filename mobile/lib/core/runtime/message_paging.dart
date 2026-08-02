import '../../client_runtime.dart';

const _messagePagePrefix = 'torchat-page-v1\t';
const _messageAllPrefix = 'torchat-all-v1\t';
const defaultMessagePageSize = 50;

class OlderMessagesResult {
  const OlderMessagesResult({required this.loadedCount, required this.hasMore});

  final int loadedCount;
  final bool hasMore;
}

class RuntimeMessagePage {
  const RuntimeMessagePage({required this.messages, required this.hasMore});

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
        : (DateTime.tryParse(
                    before.createdAt,
                  )?.toUtc().millisecondsSinceEpoch ??
                  0)
              .toString();
    final beforeId = before?.id ?? '';
    final encoded = '$_messagePagePrefix$id\t$pageSize\t$beforeAt\t$beforeId';

    final page = await messages(encoded);
    return RuntimeMessagePage(messages: page, hasMore: page.length == pageSize);
  }

  Future<List<ChatMessage>> allMessages(String conversationId) async {
    final id = _validatedConversationId(conversationId);
    final full = await messages('$_messageAllPrefix$id');
    // Test/runtime adapters from before the typed full-history command may
    // only understand a bare conversation id.  Falling back is safe for an
    // empty conversation and keeps those adapters compatible while the
    // native engines are upgraded.
    if (full.isEmpty) return messages(id);
    return full;
  }
}

String _validatedConversationId(String value) {
  final id = value.trim();
  if (id.isEmpty || id.contains('\t')) {
    throw ArgumentError.value(
      value,
      'conversationId',
      'Invalid conversation ID',
    );
  }
  return id;
}
