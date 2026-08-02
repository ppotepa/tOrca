import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/attachments/image_attachment_picker.dart';
import '../../core/attachments/image_message_codec.dart';
import '../../core/models/domain.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/async/themed_activity_indicator.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/identity_avatar.dart';
import 'release_message_bubble.dart';

class ReleaseChatView extends ConsumerStatefulWidget {
  const ReleaseChatView({
    super.key,
    required this.selected,
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.composer,
    required this.onOpenConversation,
    required this.onSend,
    required this.onTypingChanged,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onBack,
    required this.error,
    required this.notice,
    this.showConversationListWhenEmpty = true,
    this.canSend = false,
    this.peerTyping = false,
    this.peerOnline = false,
  });

  final ContactRecord? selected;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final TextEditingController composer;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<String?> onSend;
  final ValueChanged<bool> onTypingChanged;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final VoidCallback onBack;
  final String error;
  final String notice;
  final bool showConversationListWhenEmpty;
  final bool canSend;
  final bool peerTyping;
  final bool peerOnline;

  @override
  ConsumerState<ReleaseChatView> createState() => _ReleaseChatViewState();
}

class _ReleaseChatViewState extends ConsumerState<ReleaseChatView> {
  static const _nearBottomThreshold = 160.0;
  static const _scrollPositionPrefix = 'torchat.timeline.scroll.';

  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _typingTimer;
  Timer? _scrollPersistTimer;
  ChatMessage? _replyingTo;
  String? _activeConversationId;
  String _attachmentError = '';
  bool _searching = false;
  bool _nearBottom = true;
  bool _initialScrollApplied = false;
  bool _preparingImage = false;
  int _unseenMessageCount = 0;
  int _restoreGeneration = 0;
  bool _restoreInFlight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    widget.composer.addListener(_composerChanged);
  }

  @override
  void didUpdateWidget(covariant ReleaseChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.composer, widget.composer)) {
      oldWidget.composer.removeListener(_composerChanged);
      widget.composer.addListener(_composerChanged);
    }

    final conversationId = _conversationId;
    if (_activeConversationId != conversationId) {
      final previousConversationId = _activeConversationId;
      if (previousConversationId != null) {
        unawaited(_persistScrollPosition(previousConversationId));
      }
      _activeConversationId = conversationId;
      _restoreGeneration += 1;
      // Invalidate a pending restore from the previous conversation before
      // starting the new one. The old post-frame callback is generation
      // guarded and cannot mutate the new conversation.
      _restoreInFlight = false;
      _initialScrollApplied = false;
      _nearBottom = true;
      _unseenMessageCount = 0;
      _replyingTo = null;
      _attachmentError = '';
      if (widget.messages.isNotEmpty) {
        unawaited(_restoreInitialPosition(conversationId, _restoreGeneration));
      }
      return;
    }

    if (!_initialScrollApplied && widget.messages.isNotEmpty) {
      if (!_restoreInFlight) {
        unawaited(_restoreInitialPosition(conversationId, _restoreGeneration));
      }
      return;
    }

    if (widget.messages.length <= oldWidget.messages.length) return;
    final oldIds = oldWidget.messages.map((message) => message.id).toSet();
    final added = widget.messages
        .where((message) => !oldIds.contains(message.id))
        .toList(growable: false);
    if (added.isEmpty) return;

    // The repository provides the complete active-conversation projection.
    // Never keep a window size derived from the number of rows that happened
    // to exist when the chat was first opened: that made a chat opened with
    // one message display only the newest row forever.
    if (mounted) {
      final followLatest =
          added.any((message) => message.outgoing) || _nearBottom;
      setState(() {
        if (followLatest) {
          _unseenMessageCount = 0;
        } else {
          _unseenMessageCount += added.length;
        }
      });
      if (followLatest) _scheduleAnimatedBottomScroll();
    }
  }

  @override
  void dispose() {
    final conversationId = _activeConversationId;
    if (conversationId != null) {
      unawaited(_persistScrollPosition(conversationId));
    }
    widget.composer.removeListener(_composerChanged);
    _scroll.removeListener(_handleScroll);
    _scroll.dispose();
    _search.dispose();
    _typingTimer?.cancel();
    _scrollPersistTimer?.cancel();
    widget.onTypingChanged(false);
    super.dispose();
  }

  String get _conversationId {
    final contactId = widget.selected?.id ?? '';
    for (final conversation in widget.conversations) {
      if (conversation.contactId == contactId) return conversation.id;
    }
    return contactId;
  }

  List<ChatMessage> get _visibleMessages {
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      return widget.messages
          .where((message) {
            if (isImageMessageBody(message.text)) return query == 'obraz';
            return message.text.toLowerCase().contains(query);
          })
          .toList(growable: false);
    }
    return widget.messages;
  }

  void _composerChanged() {
    if (mounted) setState(() {});
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    _scheduleScrollPersist();
    if (!_initialScrollApplied) return;

    final remaining = _scroll.position.maxScrollExtent - _scroll.offset;
    final nextNearBottom = remaining <= _nearBottomThreshold;
    if (nextNearBottom == _nearBottom &&
        !(nextNearBottom && _unseenMessageCount > 0)) {
      return;
    }
    setState(() {
      _nearBottom = nextNearBottom;
      if (_nearBottom) _unseenMessageCount = 0;
    });
  }

  Future<void> _restoreInitialPosition(
    String conversationId,
    int generation,
  ) async {
    if (_restoreInFlight ||
        conversationId.isEmpty ||
        widget.messages.isEmpty ||
        generation != _restoreGeneration) {
      return;
    }
    _restoreInFlight = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedOffset = preferences.getDouble(
        '$_scrollPositionPrefix$conversationId',
      );
      if (!mounted ||
          _activeConversationId != conversationId ||
          generation != _restoreGeneration) {
        if (generation == _restoreGeneration) _restoreInFlight = false;
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _activeConversationId != conversationId ||
            generation != _restoreGeneration ||
            !_scroll.hasClients) {
          if (generation == _restoreGeneration) _restoreInFlight = false;
          return;
        }
        final maxExtent = _scroll.position.maxScrollExtent;
        final target = savedOffset == null
            ? maxExtent
            : savedOffset.clamp(0.0, maxExtent).toDouble();
        _scroll.jumpTo(target);
        final remaining = maxExtent - target;
        setState(() {
          _initialScrollApplied = true;
          _nearBottom = remaining <= _nearBottomThreshold;
          if (_nearBottom) _unseenMessageCount = 0;
        });
        if (generation == _restoreGeneration) _restoreInFlight = false;
      });
    } catch (_) {
      if (generation == _restoreGeneration) _restoreInFlight = false;
    }
  }

  void _scheduleScrollPersist() {
    _scrollPersistTimer?.cancel();
    _scrollPersistTimer = Timer(const Duration(milliseconds: 350), () {
      final conversationId = _activeConversationId;
      if (conversationId != null) {
        unawaited(_persistScrollPosition(conversationId));
      }
    });
  }

  Future<void> _persistScrollPosition(String conversationId) async {
    if (conversationId.isEmpty || !_scroll.hasClients) return;
    final offset = _scroll.offset;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(
      '$_scrollPositionPrefix$conversationId',
      offset,
    );
  }

  void _scheduleAnimatedBottomScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      if (mounted) {
        setState(() {
          _nearBottom = true;
          _unseenMessageCount = 0;
        });
      }
    });
  }

  void _typingChanged(String value) {
    _typingTimer?.cancel();
    final typing = value.trim().isNotEmpty;
    widget.onTypingChanged(typing);
    if (typing) {
      _typingTimer = Timer(
        const Duration(seconds: 2),
        () => widget.onTypingChanged(false),
      );
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_preparingImage || !widget.canSend) return;
    setState(() {
      _preparingImage = true;
      _attachmentError = '';
    });
    try {
      final prepared = await pickPreparedImageAttachment();
      if (prepared == null || !mounted) return;
      final draft = widget.composer.text;
      widget.composer.text = prepared.toMessageBody();
      widget.onSend(null);
      widget.composer.text = draft;
      _scheduleAnimatedBottomScroll();
    } catch (error) {
      if (mounted) {
        setState(() {
          _attachmentError = error
              .toString()
              .replaceFirst('Exception: ', '')
              .replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _preparingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = widget.selected;
    if (contact == null) return _buildConversationHome(context);

    final conversationId = _conversationId;
    final openState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationOpen(conversationId)),
    );
    final startState = ref.watch(
      uiOperationProvider(UiOperationKey.conversationStart(contact.id)),
    );
    final messagesState = ref.watch(
      uiOperationProvider(UiOperationKey.messagesLoad(conversationId)),
    );
    final sendState = ref.watch(
      uiOperationProvider(UiOperationKey.messageSend(conversationId)),
    );
    final panelState = messagesState.busy
        ? messagesState
        : openState.busy
        ? openState
        : startState;

    return BusySurface(
      state: panelState,
      presentation: widget.messages.isEmpty
          ? BusyPresentation.replace
          : BusyPresentation.overlay,
      label: startState.busy ? 'Uruchamianie rozmowy…' : 'Ładowanie rozmowy…',
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          toolbarHeight: 68,
          leading: widget.showConversationListWhenEmpty
              ? IconButton(
                  tooltip: 'Wróć',
                  onPressed: widget.onBack,
                  icon: const ThemedIcon(Icons.chevron_left),
                )
              : null,
          titleSpacing: widget.showConversationListWhenEmpty ? 0 : 16,
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Szukaj lokalnie w rozmowie…',
                    border: InputBorder.none,
                  ),
                )
              : Row(
                  children: [
                    IdentityAvatar(label: contact.displayName),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contact.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            widget.peerTyping
                                ? 'pisze…'
                                : widget.peerOnline
                                ? 'online · ${_routeLabel(contact)}'
                                : 'offline · ${_routeLabel(contact)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: widget.peerTyping || widget.peerOnline
                                      ? context.statusTheme.success
                                      : context.shellTheme.navigationForeground,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: _searching ? 'Zamknij wyszukiwanie' : 'Szukaj',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              }),
              icon: ThemedIcon(_searching ? Icons.close : Icons.search),
            ),
            PopupMenuButton<String>(
              tooltip: 'Opcje rozmowy',
              icon: const ThemedIcon(Icons.more_vert),
              onSelected: (value) async {
                if (value == 'fingerprint') {
                  await Clipboard.setData(
                    ClipboardData(text: contact.fingerprint),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'fingerprint',
                  child: Text('Kopiuj fingerprint'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (widget.notice.trim().isNotEmpty)
              _InlineStatus(message: widget.notice),
            if (widget.error.trim().isNotEmpty)
              _InlineStatus(message: widget.error, error: true),
            if (_attachmentError.isNotEmpty)
              _InlineStatus(message: _attachmentError, error: true),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _MessageTimeline(
                      controller: _scroll,
                      messages: _visibleMessages,
                      contact: contact,
                      canSend: widget.canSend,
                      onRetry: widget.onRetryMessage,
                      onDelete: widget.onDeleteMessage,
                      onReply: (message) =>
                          setState(() => _replyingTo = message),
                    ),
                  ),
                  if (!_nearBottom || _unseenMessageCount > 0)
                    Positioned(
                      right: 18,
                      bottom: 14,
                      child: FilledButton.tonalIcon(
                        onPressed: _scheduleAnimatedBottomScroll,
                        icon: const ThemedIcon(Icons.keyboard_arrow_down),
                        label: Text(
                          _unseenMessageCount > 0
                              ? '$_unseenMessageCount nowe'
                              : 'Najnowsze',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _Composer(
              controller: widget.composer,
              replyTo: _replyingTo,
              enabled: widget.canSend && !sendState.busy,
              sending: sendState.busy,
              preparingImage: _preparingImage,
              onAttach: _pickAndSendImage,
              onChanged: _typingChanged,
              onCancelReply: () => setState(() => _replyingTo = null),
              onSend: () {
                final replyId = _replyingTo?.id;
                setState(() => _replyingTo = null);
                widget.onSend(replyId);
                _scheduleAnimatedBottomScroll();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationHome(BuildContext context) {
    final recent = widget.conversations.take(4).toList(growable: false);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                Icons.shield_outlined,
                size: 54,
                color: context.statusTheme.success,
              ),
              const SizedBox(height: 14),
              Text(
                'Prywatna komunikacja przez Tor',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.contacts.length} kontaktów · '
                '${widget.conversations.length} rozmów',
              ),
              if (!widget.showConversationListWhenEmpty &&
                  recent.isNotEmpty) ...[
                const SizedBox(height: 24),
                for (final conversation in recent)
                  ListTile(
                    leading: const ThemedIcon(Icons.chat_bubble_outline),
                    title: Text(
                      _contactName(conversation.contactId, widget.contacts),
                    ),
                    subtitle: Text(
                      _previewLabel(conversation.preview),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const ThemedIcon(Icons.chevron_right),
                    onTap: () => widget.onOpenConversation(conversation.id),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageTimeline extends StatelessWidget {
  const _MessageTimeline({
    required this.controller,
    required this.messages,
    required this.contact,
    required this.canSend,
    required this.onRetry,
    required this.onDelete,
    required this.onReply,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final ContactRecord contact;
  final bool canSend;
  final ValueChanged<String> onRetry;
  final ValueChanged<String> onDelete;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            canSend
                ? 'To początek rozmowy z ${contact.displayName}.'
                : 'Rozmowa oczekuje na bezpieczne połączenie.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: ListView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            final previous = index == 0 ? null : messages[index - 1];
            final next = index + 1 >= messages.length
                ? null
                : messages[index + 1];
            final showDay =
                previous == null ||
                !isSameMessageDay(previous.createdAt, message.createdAt);
            final startsGroup =
                previous == null ||
                previous.outgoing != message.outgoing ||
                showDay;
            final endsGroup =
                next == null ||
                next.outgoing != message.outgoing ||
                !isSameMessageDay(message.createdAt, next.createdAt);

            return Column(
              key: ValueKey(message.id),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDay) _DayDivider(date: message.createdAt),
                ReleaseMessageBubble(
                  message: message,
                  contactName: contact.displayName,
                  startsGroup: startsGroup,
                  endsGroup: endsGroup,
                  onRetry: onRetry,
                  onDelete: onDelete,
                  onReply: onReply,
                ),
                SizedBox(height: endsGroup ? 10 : 3),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.replyTo,
    required this.enabled,
    required this.sending,
    required this.preparingImage,
    required this.onAttach,
    required this.onChanged,
    required this.onCancelReply,
    required this.onSend,
  });

  final TextEditingController controller;
  final ChatMessage? replyTo;
  final bool enabled;
  final bool sending;
  final bool preparingImage;
  final VoidCallback onAttach;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancelReply;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Material(
      color: shell.surface,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: shell.border)),
        ),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyTo != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 7),
                    padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            replyTo!.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Anuluj odpowiedź',
                          onPressed: onCancelReply,
                          icon: const ThemedIcon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton.filledTonal(
                      tooltip: preparingImage
                          ? 'Kompresowanie obrazu…'
                          : 'Wyślij obraz (maks. 50 KiB)',
                      onPressed: enabled && !preparingImage ? onAttach : null,
                      icon: preparingImage
                          ? const ThemedActivityIndicator(compact: true)
                          : const ThemedIcon(Icons.image_outlined, size: 19),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter): () {
                            if (enabled && controller.text.trim().isNotEmpty) {
                              onSend();
                            }
                          },
                        },
                        child: TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 5,
                          onChanged: onChanged,
                          onSubmitted: (_) {
                            if (enabled && controller.text.trim().isNotEmpty) {
                              onSend();
                            }
                          },
                          decoration: InputDecoration(
                            hintText: enabled
                                ? 'Napisz wiadomość…'
                                : 'Rozmowa nie jest jeszcze gotowa',
                            suffixIcon: FilledButton(
                              onPressed:
                                  enabled && controller.text.trim().isNotEmpty
                                  ? onSend
                                  : null,
                              child: sending
                                  ? const ThemedActivityIndicator(compact: true)
                                  : const ThemedIcon(Icons.send, size: 19),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    color: error
        ? context.statusTheme.danger.withValues(alpha: .12)
        : context.statusTheme.success.withValues(alpha: .1),
    child: Text(
      message,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: error ? context.statusTheme.danger : context.statusTheme.success,
      ),
    ),
  );
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final String date;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: context.shellTheme.surface,
        border: Border.all(color: context.shellTheme.border),
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(999),
      ),
      child: Text(
        formatMessageDay(date),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

String _routeLabel(ContactRecord contact) => switch (contact.transportPolicy) {
  ContactTransportPolicy.relayOnly => 'Tor relay',
  ContactTransportPolicy.peerWithRelayFallback =>
    contact.peerConnectionStatus == PeerConnectionStatus.connected
        ? 'Tor P2P'
        : 'Tor P2P + relay fallback',
  ContactTransportPolicy.peerOnly => 'Tor P2P',
};

String _contactName(String id, List<ContactRecord> contacts) {
  for (final contact in contacts) {
    if (contact.id == id) return contact.displayName;
  }
  return 'Kontakt';
}

String _previewLabel(String preview) {
  if (preview.isEmpty) return 'Oczekiwanie na wiadomość';
  return isImageMessageBody(preview) ? 'Obraz' : preview;
}
