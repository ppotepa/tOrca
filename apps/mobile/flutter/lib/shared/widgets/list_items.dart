import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../locales/presentation/app_localizations_x.dart';
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
    this.pinned = false,
    this.muted = false,
    this.activity = ContactActivityVisualState.unknown,
  });

  final String contactName;
  final String preview;
  final String lastMessageAt;
  final String lastSeen;
  final int unread;
  final bool selected;
  final VoidCallback onTap;
  final bool asCard;
  final bool pinned;
  final bool muted;
  final ContactActivityVisualState activity;

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
      leading: IdentityAvatar(label: contactName, activity: activity),
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
      trailing: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatMessageTime(
                lastMessageAt,
                locale: Localizations.localeOf(context).toLanguageTag(),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (hasUnread || pinned || muted) ...[
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pinned)
                    const ThemedIcon(Icons.push_pin_outlined, size: 12),
                  if (pinned && muted) const SizedBox(width: 4),
                  if (muted)
                    const ThemedIcon(
                      Icons.notifications_off_outlined,
                      size: 12,
                    ),
                  if ((pinned || muted) && hasUnread) const SizedBox(width: 5),
                  if (hasUnread)
                    CounterBadge(
                      count: unread,
                      glow: true,
                      color: unreadTheme.unreadBorder,
                    ),
                ],
              ),
            ],
          ],
        ),
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
    this.unread = 0,
    this.asCard = true,
    this.activity = ContactActivityVisualState.unknown,
  });

  final ContactRecord contact;
  final ValueChanged<ContactRecord> onTap;
  final String? subtitle;
  final Widget? trailing;
  final int unread;
  final bool asCard;
  final ContactActivityVisualState activity;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unread > 0;
    final unreadTheme = context.chatTheme;
    final trailingWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasUnread) ...[
          CounterBadge(
            count: unread,
            glow: true,
            color: unreadTheme.unreadBorder,
          ),
          const SizedBox(width: 8),
        ],
        trailing ?? const Icon(Icons.chevron_right),
      ],
    );
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => onTap(contact),
      leading: IdentityAvatar(label: contact.displayName, activity: activity),
      title: Text(
        contact.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle ??
            (contact.verified
                ? context.l10n.desktopIdentityVerified
                : context.l10n.desktopIdentityUnverified),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailingWidget,
      titleAlignment: ListTileTitleAlignment.center,
    );
    return asCard ? Card(child: tile) : tile;
  }
}
