import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/conversation_preferences.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/attachments/image_message_codec.dart';
import '../../core/models/domain.dart';
import '../async/busy_surface.dart';
import '../formatters/conversation_display.dart';
import 'empty_state.dart';
import 'feature_header.dart';
import 'list_items.dart';

class ConversationListSection extends ConsumerWidget {
  const ConversationListSection({
    super.key,
    required this.title,
    required this.conversations,
    required this.contacts,
    required this.selectedConversation,
    required this.onOpenConversation,
    this.subtitle,
    this.emptyMessage =
        'Nie masz jeszcze rozmów.\nWybierz osobę w zakładce Kontakty.',
    this.asCard = true,
    this.showHeader = true,
  });

  final String title;
  final String? subtitle;
  final List<ConversationSummary> conversations;
  final List<ContactRecord> contacts;
  final String? selectedConversation;
  final ValueChanged<String> onOpenConversation;
  final String emptyMessage;
  final bool asCard;
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listLoad = ref.watch(
      uiOperationProvider(UiOperationKey.conversationsLoad),
    );
    final preferences = ref.watch(conversationPreferencesProvider);
    final visibleConversations =
        conversations
            .where(
              (conversation) =>
                  !(preferences[conversation.id]?.archived ?? false),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftPinned = preferences[left.id]?.pinned ?? false;
            final rightPinned = preferences[right.id]?.pinned ?? false;
            if (leftPinned == rightPinned) return 0;
            return leftPinned ? -1 : 1;
          });

    final list = visibleConversations.isEmpty
        ? EmptyState(icon: Icons.chat_bubble_outline, message: emptyMessage)
        : ListView.separated(
            itemCount: visibleConversations.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final conversation = visibleConversations[index];
              final preference =
                  preferences[conversation.id] ??
                  const ConversationPreference();
              ContactRecord? contact;
              for (final candidate in contacts) {
                if (candidate.id == conversation.contactId) {
                  contact = candidate;
                  break;
                }
              }
              final protocolName =
                  contact?.displayName.trim().isNotEmpty == true
                  ? contact!.displayName
                  : 'Nieznany kontakt';
              final name = preference.localTitle?.trim().isNotEmpty == true
                  ? preference.localTitle!
                  : protocolName;
              final lastSeen = conversationLastSeenLabel(
                conversation.id,
                conversations,
              );
              final tile = ConversationListTile(
                contactName: name,
                preview: _previewLabel(conversation.preview),
                lastMessageAt: conversation.lastMessageAt,
                unread: conversation.unread,
                lastSeen: lastSeen,
                peerConnectionStatus:
                    contact?.peerConnectionStatus ??
                    PeerConnectionStatus.offline,
                transportPolicy:
                    contact?.transportPolicy ?? ContactTransportPolicy.peerOnly,
                peerEndpointStatus:
                    contact?.peerEndpointStatus ?? PeerEndpointStatus.missing,
                selected: selectedConversation == conversation.id,
                onTap: () => onOpenConversation(conversation.id),
                asCard: asCard,
                pinned: preference.pinned,
                muted: preference.muted,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPressStart: (details) => _showConversationMenu(
                      context,
                      ref,
                      conversation,
                      protocolName,
                      preference,
                      details.globalPosition,
                    ),
                    onSecondaryTapDown: (details) => _showConversationMenu(
                      context,
                      ref,
                      conversation,
                      protocolName,
                      preference,
                      details.globalPosition,
                    ),
                    child: tile,
                  ),
                ],
              );
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          FeatureHeader(title: title, subtitle: subtitle),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: BusySurface(
            state: listLoad,
            presentation: visibleConversations.isEmpty
                ? BusyPresentation.replace
                : BusyPresentation.overlay,
            label: 'Ładowanie rozmów…',
            child: list,
          ),
        ),
      ],
    );
  }

  Future<void> _showConversationMenu(
    BuildContext context,
    WidgetRef ref,
    ConversationSummary conversation,
    String protocolName,
    ConversationPreference preference,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'rename',
          child: Text('Zmień nazwę lokalną'),
        ),
        PopupMenuItem(
          value: 'pin',
          child: Text(preference.pinned ? 'Odepnij' : 'Przypnij'),
        ),
        PopupMenuItem(
          value: 'mute',
          child: Text(preference.muted ? 'Włącz powiadomienia' : 'Wycisz'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'clear_history',
          child: Text('Wyczyść lokalną historię'),
        ),
        const PopupMenuItem(
          value: 'archive',
          child: Text('Archiwizuj lokalnie'),
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    final controller = ref.read(conversationPreferencesProvider.notifier);
    switch (action) {
      case 'rename':
        final field = TextEditingController(
          text: preference.localTitle ?? protocolName,
        );
        final result = await showDialog<String?>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Lokalna nazwa rozmowy'),
            content: TextField(
              controller: field,
              autofocus: true,
              maxLength: 48,
              decoration: const InputDecoration(
                labelText: 'Nazwa',
                helperText: 'Nazwa pozostaje tylko na tym urządzeniu.',
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Anuluj'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, ''),
                child: const Text('Przywróć'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, field.text),
                child: const Text('Zapisz'),
              ),
            ],
          ),
        );
        field.dispose();
        if (result != null) await controller.setTitle(conversation.id, result);
        return;
      case 'pin':
        await controller.togglePinned(conversation.id);
        return;
      case 'mute':
        await controller.toggleMuted(conversation.id);
        return;
      case 'clear_history':
        await _clearHistory(context, ref, conversation);
        return;
      case 'archive':
        await controller.setArchived(conversation.id, true);
        return;
      default:
        return;
    }
  }

  Future<void> _clearHistory(
    BuildContext context,
    WidgetRef ref,
    ConversationSummary conversation,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Wyczyścić lokalną historię?'),
        content: const Text(
          'Wiadomości zostaną usunięte wyłącznie z tego urządzenia. '
          'Kontakt nie otrzyma informacji o tej operacji.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Wyczyść'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final runtime = ref.read(runtimeRepositoryProvider);
    final messages = await runtime.allMessages(conversation.id);
    for (final message in messages) {
      await runtime.deleteMessageLocal(message.id);
    }
    final appController = ref.read(appControllerProvider.notifier);
    await appController.refreshData(forcePairing: false, allowAutoTorka: false);
    if (selectedConversation == conversation.id) {
      await appController.openConversation(conversation.id);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lokalna historia została wyczyszczona.')),
      );
    }
  }
}

String _previewLabel(String preview) {
  if (preview.isEmpty) return '';
  return isImageMessageBody(preview) ? 'Obraz' : preview;
}
