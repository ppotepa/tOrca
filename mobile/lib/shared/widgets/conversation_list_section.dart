import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/conversation_messages_state.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../core/runtime/runtime_repository.dart';
import '../async/busy_surface.dart';
import '../async/themed_activity_indicator.dart';
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
    final messageLoad =
        ref.watch(conversationMessagesLoadEventsProvider).valueOrNull;
    final listLoad = ref.watch(
      uiOperationProvider(UiOperationKey.conversationsLoad),
    );
    final list = conversations.isEmpty
        ? EmptyState(icon: Icons.chat_bubble_outline, message: emptyMessage)
        : ListView.separated(
            itemCount: conversations.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final conversation = conversations[index];
              ContactRecord? contact;
              for (final candidate in contacts) {
                if (candidate.id == conversation.contactId) {
                  contact = candidate;
                  break;
                }
              }
              final name = contact?.nickname.trim().isNotEmpty == true
                  ? contact!.nickname
                  : 'Nieznany kontakt';
              final lastSeen = conversationLastSeenLabel(
                conversation.id,
                conversations,
              );
              final opening =
                  messageLoad?.conversationId == conversation.id &&
                  messageLoad?.phase == ConversationMessagesPhase.loading;
              final explicitOpen = ref.watch(
                uiOperationProvider(
                  UiOperationKey.conversationOpen(conversation.id),
                ),
              );
              final loading = opening || explicitOpen.busy;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConversationListTile(
                    contactName: name,
                    preview: conversation.preview,
                    lastMessageAt: conversation.lastMessageAt,
                    unread: conversation.unread,
                    lastSeen: lastSeen,
                    peerConnectionStatus:
                        contact?.peerConnectionStatus ??
                        PeerConnectionStatus.offline,
                    transportPolicy:
                        contact?.transportPolicy ??
                        ContactTransportPolicy.peerWithRelayFallback,
                    peerEndpointStatus:
                        contact?.peerEndpointStatus ?? PeerEndpointStatus.missing,
                    selected: selectedConversation == conversation.id,
                    onTap: loading
                        ? () {}
                        : () => onOpenConversation(conversation.id),
                    asCard: asCard,
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ThemedActivityIndicator(
                          label: 'Otwieranie rozmowy…',
                          compact: true,
                        ),
                      ),
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
            presentation: conversations.isEmpty
                ? BusyPresentation.replace
                : BusyPresentation.overlay,
            label: 'Ładowanie rozmów…',
            child: list,
          ),
        ),
      ],
    );
  }
}
