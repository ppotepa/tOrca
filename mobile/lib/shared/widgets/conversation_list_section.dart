import 'package:flutter/material.dart';

import '../../core/models/domain.dart';
import '../formatters/conversation_display.dart';
import 'empty_state.dart';
import 'feature_header.dart';
import 'list_items.dart';

class ConversationListSection extends StatelessWidget {
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showHeader) ...[
        FeatureHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 12),
      ],
      Expanded(
        child: conversations.isEmpty
            ? EmptyState(icon: Icons.chat_bubble_outline, message: emptyMessage)
            : ListView.separated(
                itemCount: conversations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  final contact = contacts
                      .where((item) => item.id == conversation.contactId)
                      .firstOrNull;
                  final name = contact?.nickname.trim().isNotEmpty == true
                      ? contact!.nickname
                      : 'Nieznany kontakt';
                  final lastSeen = conversationLastSeenLabel(
                    conversation.id,
                    conversations,
                  );
                  return ConversationListTile(
                    contactName: name,
                    preview: conversation.preview,
                    lastMessageAt: conversation.lastMessageAt,
                    unread: conversation.unread,
                    lastSeen: lastSeen,
                    selected: selectedConversation == conversation.id,
                    onTap: () => onOpenConversation(conversation.id),
                    asCard: asCard,
                  );
                },
              ),
      ),
    ],
  );
}
