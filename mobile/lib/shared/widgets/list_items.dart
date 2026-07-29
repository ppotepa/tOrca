import 'package:flutter/material.dart';

import '../../core/models/domain.dart';
import '../../app/app_theme.dart';
import '../formatters/message_timestamps.dart';
import 'counter_badge.dart';
import 'identity_avatar.dart';

class ConversationListTile extends StatelessWidget {
  const ConversationListTile({
    super.key,
    required this.contactName,
    required this.preview,
    required this.lastMessageAt,
    this.lastSeen = '',
    required this.unread,
    required this.selected,
    required this.onTap,
    this.asCard = false,
  });

  final String contactName;
  final String preview;
  final String lastMessageAt;
  final String lastSeen;
  final int unread;
  final bool selected;
  final VoidCallback onTap;
  final bool asCard;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unread > 0;
    final theme = context.shellTheme;
    final unreadTheme = context.chatTheme;
    final tile = ListTile(
      selected: selected,
      tileColor: selected
          ? theme.selectedNavigationBackground.withValues(alpha: .22)
          : hasUnread
          ? unreadTheme.unreadBackground.withValues(alpha: .15)
          : null,
      textColor: selected ? theme.selectedNavigationForeground : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(theme.listItemRadius),
        side: hasUnread || selected
            ? BorderSide(
                color: selected
                    ? theme.selectedNavigationBorder
                    : unreadTheme.unreadBorder.withValues(alpha: .45),
                width: theme.listItemBorderWidth,
              )
            : BorderSide.none,
      ),
      onTap: onTap,
      leading: IdentityAvatar(label: contactName),
      title: Text(
        contactName,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: hasUnread || selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: hasUnread ? FontWeight.w600 : null),
          ),
          if (lastSeen.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              lastSeen,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: unreadTheme.metadataForeground,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatMessageTime(lastMessageAt),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if (hasUnread) ...[
            const SizedBox(height: 4),
            CounterBadge(
              count: unread,
              glow: true,
              color: unreadTheme.unreadBorder,
            ),
          ],
        ],
      ),
    );
    return asCard ? Card(child: tile) : tile;
  }
}

class ContactListTile extends StatelessWidget {
  const ContactListTile({
    super.key,
    required this.contact,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.asCard = true,
  });

  final ContactRecord contact;
  final ValueChanged<ContactRecord> onTap;
  final String? subtitle;
  final Widget? trailing;
  final bool asCard;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => onTap(contact),
      leading: IdentityAvatar(label: contact.nickname),
      title: Text(contact.nickname),
      subtitle: Text(
        subtitle ??
            (contact.verified
                ? 'Gotowy do rozmowy'
                : 'Fingerprint niepotwierdzony'),
      ),
      trailing: trailing ?? const Icon(Icons.chevron_right),
    );
    return asCard ? Card(child: tile) : tile;
  }
}
