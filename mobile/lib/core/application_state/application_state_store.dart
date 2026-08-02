import 'dart:async';

import 'application_snapshot.dart';
import 'application_snapshot_patch.dart';
import '../models/domain.dart';

class ConversationMessagesSnapshot {
  const ConversationMessagesSnapshot({
    required this.conversationId,
    required this.revision,
    required this.messages,
  });

  final String conversationId;
  final int revision;
  final List<ChatMessage> messages;
}

class ApplicationStateStore {
  ApplicationStateStore();

  static final ApplicationStateStore shared = ApplicationStateStore();

  final StreamController<ApplicationSnapshot?> _changes =
      StreamController<ApplicationSnapshot?>.broadcast(sync: true);
  final StreamController<ConversationMessagesSnapshot> _messageChanges =
      StreamController<ConversationMessagesSnapshot>.broadcast(sync: true);

  ApplicationSnapshot? _current;
  bool _stale = false;
  final Map<String, List<ChatMessage>> _messages =
      <String, List<ChatMessage>>{};
  final Map<String, int> _messageRevisions = <String, int>{};
  List<PairingItem> _pairingInbox = const <PairingItem>[];
  List<PairingItem> _pairingOutbox = const <PairingItem>[];

  ApplicationSnapshot? get current => _current;

  bool get hasSnapshot => _current != null;

  bool get isStale => _stale;

  Stream<ApplicationSnapshot?> get changes => _changes.stream;

  Stream<ApplicationSnapshot?> watchApplication() {
    late final StreamSubscription<ApplicationSnapshot?> subscription;
    return Stream<ApplicationSnapshot?>.multi((controller) {
      // Subscribe before publishing the retained value. Pairing completion
      // can publish a contact and conversation between a plain `current`
      // read and a later stream subscription, leaving lists stale until a
      // navigation change or process restart.
      subscription = changes.listen(
        controller.addSync,
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      controller.addSync(current);
      controller.onCancel = subscription.cancel;
    });
  }

  Stream<ConversationMessagesSnapshot> get messageChanges =>
      _messageChanges.stream;

  Stream<ConversationMessagesSnapshot> watchMessages(String conversationId) {
    late final StreamSubscription<ConversationMessagesSnapshot> subscription;
    return Stream<ConversationMessagesSnapshot>.multi((controller) {
      // Subscribe before publishing the retained value. This closes the race
      // where an engine event arrived between `yield current` and `yield*`,
      // leaving the open chat stuck on a partial history until navigation.
      subscription = messageChanges
          .where((snapshot) => snapshot.conversationId == conversationId)
          .listen(
            controller.addSync,
            onError: controller.addErrorSync,
            onDone: controller.closeSync,
          );
      controller.addSync(messageSnapshot(conversationId));
      controller.onCancel = subscription.cancel;
    });
  }

  List<ChatMessage> messages(String conversationId) =>
      _messages[conversationId] ?? const <ChatMessage>[];

  ConversationMessagesSnapshot messageSnapshot(String conversationId) =>
      ConversationMessagesSnapshot(
        conversationId: conversationId,
        revision: _messageRevisions[conversationId] ?? 0,
        messages: messages(conversationId),
      );

  void replaceMessages(String conversationId, List<ChatMessage> messages) {
    final immutable = List<ChatMessage>.unmodifiable(messages);
    _publishMessages(conversationId, immutable);
  }

  List<ChatMessage> mergeMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) {
    final byId = <String, ChatMessage>{
      for (final message in this.messages(conversationId)) message.id: message,
      for (final message in messages) message.id: message,
    };
    final merged = byId.values.toList(growable: false);
    final retainedOrder = <String, int>{
      for (var index = 0; index < merged.length; index += 1)
        merged[index].id: index,
    };
    merged.sort((left, right) {
      final byTime = _compareMessageTime(left, right);
      if (byTime != 0) return byTime;
      // UUIDs are identifiers, not chronology. Preserve the canonical order
      // returned by storage when timestamps collide within one millisecond.
      return retainedOrder[left.id]!.compareTo(retainedOrder[right.id]!);
    });
    final immutable = List<ChatMessage>.unmodifiable(merged);
    _publishMessages(conversationId, immutable);
    return immutable;
  }

  String? removeMessage(String messageId) {
    for (final entry in _messages.entries.toList(growable: false)) {
      final retained = entry.value
          .where((message) => message.id != messageId)
          .toList(growable: false);
      if (retained.length == entry.value.length) continue;
      _publishMessages(entry.key, List<ChatMessage>.unmodifiable(retained));
      return entry.key;
    }
    return null;
  }

  void _publishMessages(String conversationId, List<ChatMessage> immutable) {
    _messages[conversationId] = immutable;
    final revision = (_messageRevisions[conversationId] ?? 0) + 1;
    _messageRevisions[conversationId] = revision;
    _messageChanges.add(
      ConversationMessagesSnapshot(
        conversationId: conversationId,
        revision: revision,
        messages: immutable,
      ),
    );
  }

  static int _compareMessageTime(ChatMessage left, ChatMessage right) {
    final leftAt = DateTime.tryParse(left.createdAt)?.toUtc();
    final rightAt = DateTime.tryParse(right.createdAt)?.toUtc();
    if (leftAt != null && rightAt != null) {
      final byTime = leftAt.compareTo(rightAt);
      if (byTime != 0) return byTime;
    } else if (leftAt != null) {
      return 1;
    } else if (rightAt != null) {
      return -1;
    }
    return 0;
  }

  List<PairingItem> get pairingInbox => _pairingInbox;
  List<PairingItem> get pairingOutbox => _pairingOutbox;

  void setPairing(List<PairingItem> inbox, List<PairingItem> outbox) {
    _pairingInbox = List<PairingItem>.unmodifiable(inbox);
    _pairingOutbox = List<PairingItem>.unmodifiable(outbox);
  }

  bool hydrate(ApplicationSnapshot snapshot) {
    final current = _current;
    final currentIdentity = current?.identity.installationId.trim() ?? '';
    final nextIdentity = snapshot.identity.installationId.trim();
    if (current != null &&
        currentIdentity.isNotEmpty &&
        nextIdentity.isNotEmpty &&
        currentIdentity != nextIdentity) {
      _current = null;
      _stale = false;
      _changes.add(null);
    } else if (current != null &&
        current.projectionStoreId.isNotEmpty &&
        snapshot.projectionStoreId == current.projectionStoreId &&
        snapshot.projectionRevision < current.projectionRevision) {
      // A response from an older engine revision must never roll the
      // application projection back, even if its Future completed later.
      return false;
    } else if (current != null && snapshot.generation < current.generation) {
      return false;
    }
    _current = snapshot;
    _stale = false;
    _changes.add(snapshot);
    return true;
  }

  bool applyPatch(ApplicationSnapshotPatch patch) {
    final current = _current;
    if (current == null || !patch.canApplyTo(current)) return false;
    _current = patch.applyTo(current);
    _stale = false;
    _changes.add(_current);
    return true;
  }

  void markStale() {
    if (_current == null || _stale) return;
    _stale = true;
  }

  void clear() {
    _current = null;
    _stale = false;
    _messages.clear();
    _messageRevisions.clear();
    _pairingInbox = const <PairingItem>[];
    _pairingOutbox = const <PairingItem>[];
    _changes.add(null);
  }
}
