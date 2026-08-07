import 'package:flutter_test/flutter_test.dart';

import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/runtime/message_paging.dart';

void main() {
  test('messagePage encodes a valid conversation id with page size', () async {
    final runtime = _FakeRuntime();
    runtime.reply = const [ChatMessage(id: 'm1', text: 'hi', outgoing: true, state: MessageState.sent)];

    final page = await runtime.messagePage('convo-1');

    expect(runtime.lastEncoded, 'torchat-page-v1\tconvo-1\t50\t\t');
    expect(page.hasMore, isFalse);
    expect(page.messages, hasLength(1));
  });

  test('messagePage clamps the requested limit into the allowed range', () async {
    final runtime = _FakeRuntime();

    await runtime.messagePage('convo-1', limit: 0);
    expect(runtime.lastEncoded, 'torchat-page-v1\tconvo-1\t1\t\t');

    await runtime.messagePage('convo-1', limit: 5000);
    expect(runtime.lastEncoded, 'torchat-page-v1\tconvo-1\t200\t\t');
  });

  test('messagePage encodes the before cursor timestamp and id', () async {
    final runtime = _FakeRuntime();
    final before = ChatMessage(
      id: 'anchor-7',
      text: 'older',
      outgoing: false,
      state: MessageState.read,
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5).toIso8601String(),
    );

    await runtime.messagePage('convo-1', before: before, limit: 10);

    expect(runtime.lastEncoded, 'torchat-page-v1\tconvo-1\t10\t1767323045000\tanchor-7');
  });

  test('hasMore is true when a full page is returned', () async {
    final runtime = _FakeRuntime();
    runtime.reply = List.generate(50, (i) => ChatMessage(id: 'm$i', text: 'x', outgoing: true, state: MessageState.sent));

    final page = await runtime.messagePage('convo-1', limit: 50);

    expect(page.hasMore, isTrue);
  });

  test('allMessages uses the full-history prefix and falls back to bare id', () async {
    final runtime = _FakeRuntime();
    runtime.reply = const [ChatMessage(id: 'm1', text: 'a', outgoing: true, state: MessageState.sent)];

    final full = await runtime.allMessages('convo-1');
    expect(runtime.lastEncoded, 'torchat-all-v1\tconvo-1');
    expect(full, hasLength(1));

    runtime.reply = const [];
    final fallback = await runtime.allMessages('convo-1');
    expect(runtime.lastEncoded, 'convo-1');
    expect(fallback, isEmpty);
  });

  test('paging rejects empty and tab-containing conversation ids', () async {
    final runtime = _FakeRuntime();

    expect(
      () => runtime.messagePage('  '),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => runtime.messagePage('bad\tid'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => runtime.allMessages(''),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('messagePage propagates runtime errors', () async {
    final runtime = _FakeRuntime();
    runtime.error = StateError('engine unavailable');

    await expectLater(
      runtime.messagePage('convo-1'),
      throwsA(isA<StateError>()),
    );
  });
}

class _FakeRuntime implements ClientRuntime {
  String lastEncoded = '';
  List<ChatMessage> reply = const [];
  Object? error;

  @override
  Future<List<ChatMessage>> messages(String id) async {
    lastEncoded = id;
    if (error != null) throw error!;
    return reply;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        '${invocation.memberName} is not implemented by _FakeRuntime',
      );
}
