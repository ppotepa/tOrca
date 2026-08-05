import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notifications/ui_notification_center.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../locales/presentation/app_localizations_x.dart';
import 'empty_state.dart';
import 'feature_header.dart';
import 'identity_avatar.dart';
import 'list_items.dart';

class ContactListSection extends ConsumerWidget {
  const ContactListSection({
    super.key,
    required this.title,
    required this.contacts,
    required this.onSelect,
    this.subtitle,
    this.emptyMessage,
    this.asCard = true,
    this.showHeader = true,
    this.contactSubtitleBuilder,
    this.contactTrailingBuilder,
    this.contactUnreadBuilder,
    this.onDetails,
    this.onToggleMute,
    this.onRemove,
    this.contactActivityBuilder,
  });

  final String title;
  final String? subtitle;
  final List<ContactRecord> contacts;
  final ValueChanged<ContactRecord> onSelect;
  final String? emptyMessage;
  final bool asCard;
  final bool showHeader;
  final String Function(ContactRecord contact)? contactSubtitleBuilder;
  final Widget Function(ContactRecord contact)? contactTrailingBuilder;
  final int Function(ContactRecord contact)? contactUnreadBuilder;
  final ValueChanged<ContactRecord>? onDetails;
  final Future<void> Function(ContactRecord contact)? onToggleMute;
  final Future<void> Function(ContactRecord contact)? onRemove;
  final ContactActivityVisualState Function(ContactRecord contact)?
  contactActivityBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showHeader) ...[
        FeatureHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 10),
      ],
      Expanded(
        child: contacts.isEmpty
            ? EmptyState(
                icon: Icons.people_outline,
                message: emptyMessage ?? context.l10n.uiNoContacts,
              )
            : ListView.separated(
                itemCount: contacts.length,
                separatorBuilder: (_, _) => const SizedBox(height: 5),
                itemBuilder: (context, index) {
                  final contact = contacts[index];
                  return Semantics(
                    container: true,
                    label: context.l10n.contactSemantics(contact.displayName),
                    hint: context.l10n.contactSemanticsHint,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: (details) => _showContextMenu(
                        context,
                        ref,
                        contact,
                        details.globalPosition,
                      ),
                      onSecondaryTapDown: (details) => _showContextMenu(
                        context,
                        ref,
                        contact,
                        details.globalPosition,
                      ),
                      child: ContactListTile(
                        contact: contact,
                        onTap: onSelect,
                        subtitle: contactSubtitleBuilder?.call(contact),
                        trailing: contactTrailingBuilder?.call(contact),
                        unread: contactUnreadBuilder?.call(contact) ?? 0,
                        activity:
                            contactActivityBuilder?.call(contact) ??
                            ContactActivityVisualState.unknown,
                        asCard: asCard,
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    ContactRecord contact,
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
        PopupMenuItem(
          value: 'open',
          child: Text(context.l10n.contactStartConversation),
        ),
        if (onDetails != null)
          PopupMenuItem(
            value: 'details',
            child: Text(context.l10n.contactDetails),
          ),
        if (onToggleMute != null)
          PopupMenuItem(
            value: 'mute',
            child: Text(
              contact.muted
                  ? context.l10n.contactEnableNotifications
                  : context.l10n.contactMute,
            ),
          ),
        PopupMenuItem(
          value: 'copy',
          child: Text(context.l10n.contactCopyFingerprint),
        ),
        if (onRemove != null)
          PopupMenuItem(
            value: 'remove',
            child: Text(
              context.l10n.contactEndRelationship,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'open':
        onSelect(contact);
        return;
      case 'details':
        onDetails?.call(contact);
        return;
      case 'mute':
        await onToggleMute?.call(contact);
        return;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: contact.fingerprint));
        if (context.mounted) {
          ref
              .read(uiNotificationCenterProvider.notifier)
              .showSuccess(
                context.l10n.uiFingerprintCopied,
                deduplicationKey: 'fingerprint-copied:${contact.id}',
              );
        }
        return;
      case 'remove':
        await onRemove?.call(contact);
        return;
      default:
        return;
    }
  }
}
