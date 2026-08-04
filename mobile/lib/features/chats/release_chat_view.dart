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
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../core/runtime/message_paging.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/generated/app_localizations.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/async/themed_activity_indicator.dart';
import '../../shared/formatters/message_timestamps.dart';
import '../../shared/widgets/identity_avatar.dart';
import 'chat_view_components.dart';
import 'composer_draft.dart';
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
    this.onConversationFocusChanged = _ignoreConversationFocus,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onLoadOlderMessages,
    required this.onBack,
    required this.error,
    this.showConversationListWhenEmpty = true,
    this.canSend = false,
    this.peerTyping = false,
    this.availability = ContactAvailability.unknown,
    this.peerFocused = false,
    this.lastSeenAt,
    this.headerStatus,
  });

  final ContactRecord? selected;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final TextEditingController composer;
  final ValueChanged<String> onOpenConversation;
  final Future<void> Function(ComposerDraft draft) onSend;
  final ValueChanged<bool> onTypingChanged;
  final void Function(String conversationId, bool focused)
  onConversationFocusChanged;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final Future<OlderMessagesResult> Function() onLoadOlderMessages;
  final VoidCallback onBack;
  final String error;
  final bool showConversationListWhenEmpty;
  final bool canSend;
  final bool peerTyping;
  final ContactAvailability availability;
  final bool peerFocused;
  final int? lastSeenAt;
  final Widget? headerStatus;

  @override
  ConsumerState<ReleaseChatView> createState() => _ReleaseChatViewState();
}

void _ignoreConversationFocus(String conversationId, bool focused) {}

class _ReleaseChatViewState extends ConsumerState<ReleaseChatView> {
  static const _nearBottomThreshold = 160.0;
  static const _scrollPositionPrefix = 'torchat.timeline.scroll.';

  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _typingTimer;
  Timer? _focusHeartbeat;
  Timer? _scrollPersistTimer;
  ChatMessage? _replyingTo;
  String? _activeConversationId;
  String _attachmentError = '';
  bool _searching = false;
  bool _nearBottom = true;
  bool _initialScrollApplied = false;
  bool _preparingImage = false;
  bool _loadingOlder = false;
  bool _hasOlderMessages = true;
  final List<ComposerAttachment> _draftAttachments = <ComposerAttachment>[];
  int _unseenMessageCount = 0;
  int _restoreGeneration = 0;
  bool _restoreInFlight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    widget.composer.addListener(_composerChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncFocus(null, _conversationId),
    );
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
      _syncFocus(previousConversationId, conversationId);
      if (previousConversationId != null) {
        unawaited(_persistScrollPosition(previousConversationId));
      }
      _activeConversationId = conversationId;
      _restoreGeneration += 1;
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
    _focusHeartbeat?.cancel();
    if (conversationId != null) {
      widget.onConversationFocusChanged(conversationId, false);
    }
    _scrollPersistTimer?.cancel();
    widget.onTypingChanged(false);
    super.dispose();
  }

  void _syncFocus(String? previous, String current) {
    _focusHeartbeat?.cancel();
    if (previous != null && previous.isNotEmpty && previous != current) {
      widget.onConversationFocusChanged(previous, false);
    }
    if (current.isEmpty) return;
    widget.onConversationFocusChanged(current, true);
    _focusHeartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      widget.onConversationFocusChanged(current, true);
    });
  }

  String get _conversationId {
    final contactId = widget.selected?.id ?? '';
    for (final conversation in widget.conversations) {
      if (conversation.contactId == contactId) return conversation.id;
    }
    return contactId;
  }

  List<ChatMessage> _visibleMessages(AppLocalizations l10n) {
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      return widget.messages
          .where((message) {
            if (isImageMessageBody(message.text)) {
              return query == l10n.uiImageSearchKeyword ||
                  query == l10n.commonImage.toLowerCase();
            }
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
    if (_scroll.position.pixels <= 240 &&
        !_loadingOlder &&
        _hasOlderMessages &&
        widget.messages.isNotEmpty) {
      unawaited(_loadOlderMessages());
    }
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

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasOlderMessages || !mounted) return;
    final beforePixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final beforeExtent = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    setState(() => _loadingOlder = true);
    try {
      final result = await widget.onLoadOlderMessages();
      _hasOlderMessages = result.hasMore;
      if (result.loadedCount > 0 && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final delta = _scroll.position.maxScrollExtent - beforeExtent;
          _scroll.jumpTo(
            (beforePixels + delta).clamp(0.0, _scroll.position.maxScrollExtent),
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
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

  Future<void> _pickAttachments() async {
    if (_preparingImage || !widget.canSend) return;
    setState(() {
      _preparingImage = true;
      _attachmentError = '';
    });
    try {
      final prepared = await pickPreparedImageAttachments();
      if (prepared == null || !mounted) return;
      final remaining = maxComposerAttachments - _draftAttachments.length;
      if (prepared.length > remaining) {
        setState(() {
          _attachmentError =
              context.l10n.uiAttachmentLimitExceeded(maxComposerAttachments);
        });
        return;
      }
      setState(() {
        _draftAttachments.addAll(
          prepared.map(
            (attachment) => ComposerAttachment(
              attachment: attachment,
              previewBytes: attachment.bytes,
            ),
          ),
        );
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _attachmentError = context.l10n.uiAttachmentPreparationFailed;
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
    final compactHeader = MediaQuery.sizeOf(context).width < 420;

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
      label: startState.busy
          ? context.l10n.chatStarting
          : context.l10n.chatLoading,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          toolbarHeight: 64,
          leading: widget.showConversationListWhenEmpty
              ? IconButton(
                  tooltip: context.l10n.chatBack,
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
                  decoration: InputDecoration(
                    hintText: context.l10n.chatSearchHint,
                    border: InputBorder.none,
                  ),
                )
              : Row(
                  children: [
                    IdentityAvatar(
                      label: contact.displayName,
                      activity: widget.peerTyping
                          ? ContactActivityVisualState.typing
                          : _availabilityVisual(widget.availability),
                    ),
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
                            contactActivityLabel(
                              context.l10n,
                              widget.peerTyping
                                  ? ContactActivityVisualState.typing
                                  : _availabilityVisual(widget.availability),
                              lastSeenAt: widget.lastSeenAt,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color:
                                      widget.peerTyping ||
                                          widget.availability ==
                                              ContactAvailability.active
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
            if (widget.peerFocused)
              ConversationHeaderAction(
                tooltip: context.l10n.chatContactViewing,
                child: ThemedIcon(Icons.visibility_outlined, size: 19),
              ),
            if (widget.headerStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Center(child: widget.headerStatus!),
              ),
            if (!compactHeader)
              ConversationHeaderAction(
                tooltip: _searching
                    ? context.l10n.chatCloseSearch
                    : context.l10n.chatSearch,
                onPressed: _toggleSearch,
                child: ThemedIcon(
                  _searching ? Icons.close : Icons.search,
                  size: 19,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 3, right: 8),
              child: SizedBox.square(
                dimension: 40,
                child: PopupMenuButton<String>(
                  tooltip: context.l10n.chatOptions,
                  icon: const ThemedIcon(Icons.more_vert, size: 19),
                  padding: EdgeInsets.zero,
                  onSelected: (value) async {
                    if (value == 'search') {
                      _toggleSearch();
                      return;
                    }
                    if (value == 'fingerprint') {
                      await Clipboard.setData(
                        ClipboardData(text: contact.fingerprint),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    if (compactHeader)
                      PopupMenuItem(
                        value: 'search',
                        child: Text(
                          _searching
                              ? context.l10n.chatCloseSearch
                              : context.l10n.chatSearch,
                        ),
                      ),
                    PopupMenuItem(
                      value: 'fingerprint',
                      child: Text(context.l10n.chatCopyFingerprint),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (widget.error.trim().isNotEmpty)
              InlineStatus(message: widget.error, error: true),
            if (_attachmentError.isNotEmpty)
              InlineStatus(message: _attachmentError, error: true),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _MessageTimeline(
                      controller: _scroll,
                      messages: _visibleMessages(context.l10n),
                      contact: contact,
                      canSend: widget.canSend,
                      onRetry: widget.onRetryMessage,
                      onDelete: widget.onDeleteMessage,
                      onReply: (message) =>
                          setState(() => _replyingTo = message),
                    ),
                  ),
                  if (_loadingOlder)
                    Positioned(
                      top: 6,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: ThemedActivityIndicator(
                          label: context.l10n.chatLoadingOlder,
                          compact: true,
                        ),
                      ),
                    ),
                  if (!_nearBottom || _unseenMessageCount > 0)
                    Positioned(
                      right: 18,
                      bottom: 14,
                      child: Tooltip(
                        message: _unseenMessageCount > 0
                            ? context.l10n.chatUnseenMessages(
                                _unseenMessageCount,
                              )
                            : context.l10n.chatScrollToBottom,
                        child: Badge(
                          isLabelVisible: _unseenMessageCount > 0,
                          label: Text('$_unseenMessageCount'),
                          child: FloatingActionButton.small(
                            heroTag: 'conversation-scroll-bottom',
                            onPressed: _scheduleAnimatedBottomScroll,
                            child: const ThemedIcon(Icons.keyboard_arrow_down),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _Composer(
              controller: widget.composer,
              replyTo: _replyingTo,
              enabled: widget.canSend,
              sending: sendState.busy,
              preparingImage: _preparingImage,
              attachments: _draftAttachments,
              onRemoveAttachment: (index) =>
                  setState(() => _draftAttachments.removeAt(index)),
              onAttach: _pickAttachments,
              onChanged: _typingChanged,
              onCancelReply: () => setState(() => _replyingTo = null),
              onSend: () async {
                final replyId = _replyingTo?.id;
                setState(() => _replyingTo = null);
                final draft = ComposerDraft(
                  caption: widget.composer.text.trim(),
                  attachments: List.unmodifiable(_draftAttachments),
                  replyToMessageId: replyId,
                );
                await widget.onSend(draft);
                if (!mounted) return;
                _draftAttachments.clear();
                widget.composer.clear();
                widget.onTypingChanged(false);
                setState(() {});
                _scheduleAnimatedBottomScroll();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) _search.clear();
  });

  Widget _buildConversationHome(BuildContext context) {
    final presence = ref.watch(contactPresenceStoreProvider);
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
                context.l10n.chatPrivateCommunication,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.chatCounts(
                  widget.contacts.length,
                  widget.conversations.length,
                ),
              ),
              if (recent.isNotEmpty) ...[
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.chatRecentConversations,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                for (final conversation in recent)
                  Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      leading: IdentityAvatar(
                        label: _contactName(
                          context.l10n,
                          conversation.contactId,
                          widget.contacts,
                        ),
                        activity: switch (presence
                            .snapshot(conversation.contactId)
                            .availability) {
                          ContactAvailability.active =>
                            ContactActivityVisualState.online,
                          ContactAvailability.idle =>
                            ContactActivityVisualState.away,
                          ContactAvailability.checking =>
                            ContactActivityVisualState.typing,
                          ContactAvailability.offline =>
                            ContactActivityVisualState.offline,
                          ContactAvailability.unknown =>
                            ContactActivityVisualState.unknown,
                        },
                      ),
                      title: Text(
                        _contactName(
                          context.l10n,
                          conversation.contactId,
                          widget.contacts,
                        ),
                      ),
                      subtitle: Text(
                        _previewLabel(context.l10n, conversation.preview),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [ThemedIcon(Icons.chevron_right)],
                      ),
                      onTap: () => widget.onOpenConversation(conversation.id),
                    ),
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
      if (!contact.verified) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.l10n.chatVerifyContact,
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: canSend
              ? Text(
                  context.l10n.chatConversationStarted(contact.displayName),
                  textAlign: TextAlign.center,
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      label: context.l10n.chatSecureConnectionStarting,
                      child: const SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      context.l10n.chatWaitingForSecureConnection,
                      textAlign: TextAlign.center,
                    ),
                  ],
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
          cacheExtent: 320,
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
                if (showDay) DayDivider(date: message.createdAt),
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
    required this.attachments,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onChanged,
    required this.onCancelReply,
    required this.onSend,
  });

  final TextEditingController controller;
  final ChatMessage? replyTo;
  final bool enabled;
  final bool sending;
  final bool preparingImage;
  final List<ComposerAttachment> attachments;
  final VoidCallback onAttach;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancelReply;
  final Future<void> Function() onSend;

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
                if (attachments.isNotEmpty)
                  SizedBox(
                    height: 68,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 7),
                      itemBuilder: (context, index) {
                        final attachment = attachments[index];
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                attachment.previewBytes,
                                width: 60,
                                height: 60,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                              ),
                            ),
                            Positioned(
                              top: -5,
                              right: -5,
                              child: IconButton.filledTonal(
                                tooltip: context.l10n.chatRemoveAttachment,
                                onPressed: () => onRemoveAttachment(index),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 22,
                                  height: 22,
                                ),
                                icon: const ThemedIcon(Icons.close, size: 13),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
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
                          tooltip: context.l10n.chatCancelReply,
                          onPressed: onCancelReply,
                          icon: const ThemedIcon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton.filledTonal(
                        tooltip: preparingImage
                            ? context.l10n.chatPreparingImages
                            : context.l10n.chatAddImages,
                        onPressed: enabled && !preparingImage ? onAttach : null,
                        icon: preparingImage
                            ? const ThemedActivityIndicator(compact: true)
                            : const ThemedIcon(
                                Icons.add_photo_alternate_outlined,
                                size: 19,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter): () {
                            if (enabled &&
                                !sending &&
                                (controller.text.trim().isNotEmpty ||
                                    attachments.isNotEmpty)) {
                              unawaited(onSend());
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
                            if (enabled &&
                                !sending &&
                                (controller.text.trim().isNotEmpty ||
                                    attachments.isNotEmpty)) {
                              unawaited(onSend());
                            }
                          },
                          decoration: InputDecoration(
                            hintText: enabled
                                ? context.l10n.chatComposeHint
                                : context.l10n.chatNotReady,
                            constraints: const BoxConstraints(minHeight: 44),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox.square(
                      dimension: 44,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size.square(44),
                        ),
                        onPressed:
                            enabled &&
                                !sending &&
                                (controller.text.trim().isNotEmpty ||
                                    attachments.isNotEmpty)
                            ? () => unawaited(onSend())
                            : null,
                        child: sending
                            ? const ThemedActivityIndicator(compact: true)
                            : const ThemedIcon(Icons.send_rounded, size: 19),
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

ContactActivityVisualState _availabilityVisual(ContactAvailability value) =>
    switch (value) {
      ContactAvailability.active => ContactActivityVisualState.online,
      ContactAvailability.idle => ContactActivityVisualState.away,
      ContactAvailability.checking => ContactActivityVisualState.typing,
      ContactAvailability.offline => ContactActivityVisualState.offline,
      ContactAvailability.unknown => ContactActivityVisualState.unknown,
    };

String _contactName(
  AppLocalizations l10n,
  String id,
  List<ContactRecord> contacts,
) {
  for (final contact in contacts) {
    if (contact.id == id) return contact.displayName;
  }
  return l10n.commonContact;
}

String _previewLabel(AppLocalizations l10n, String preview) {
  if (preview.isEmpty) return l10n.chatWaitingForMessage;
  return isImageMessageBody(preview) ? l10n.commonImage : preview;
}
