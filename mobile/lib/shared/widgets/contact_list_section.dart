import 'package:flutter/material.dart';

import '../../core/models/domain.dart';
import 'empty_state.dart';
import 'feature_header.dart';
import 'list_items.dart';

class ContactListSection extends StatelessWidget {
  const ContactListSection({
    super.key,
    required this.title,
    required this.contacts,
    required this.onSelect,
    this.subtitle,
    this.emptyMessage = 'Brak kontaktów.',
    this.asCard = true,
    this.showHeader = true,
    this.contactSubtitleBuilder,
    this.contactTrailingBuilder,
  });

  final String title;
  final String? subtitle;
  final List<ContactRecord> contacts;
  final ValueChanged<ContactRecord> onSelect;
  final String emptyMessage;
  final bool asCard;
  final bool showHeader;
  final String Function(ContactRecord contact)? contactSubtitleBuilder;
  final Widget Function(ContactRecord contact)? contactTrailingBuilder;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showHeader) ...[
        FeatureHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 10),
      ],
      Expanded(
        child: contacts.isEmpty
            ? EmptyState(icon: Icons.people_outline, message: emptyMessage)
            : ListView.separated(
                itemCount: contacts.length,
                separatorBuilder: (_, _) => const SizedBox(height: 5),
                itemBuilder: (context, index) {
                  final contact = contacts[index];
                  return ContactListTile(
                    contact: contact,
                    onTap: onSelect,
                    subtitle: contactSubtitleBuilder?.call(contact),
                    trailing: contactTrailingBuilder?.call(contact),
                    asCard: asCard,
                  );
                },
              ),
      ),
    ],
  );
}
