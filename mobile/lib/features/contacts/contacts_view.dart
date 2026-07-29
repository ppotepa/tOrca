import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/status_banner.dart';

class ContactsView extends StatelessWidget {
  const ContactsView({
    super.key,
    required this.saved,
    required this.search,
    required this.onSearch,
    required this.onSelect,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.fingerprint,
    required this.ownInvite,
    required this.error,
    required this.notice,
    required this.busy,
    this.showContactList = true,
  });
  final List<ContactRecord> saved;
  final TextEditingController search;
  final VoidCallback onSearch;
  final ValueChanged<ContactRecord> onSelect;
  final VoidCallback onScanInvite, onShowInvite;
  final String fingerprint, ownInvite;
  final String error, notice;
  final bool busy;
  final bool showContactList;
  @override
  Widget build(BuildContext context) {
    final visible = <ContactRecord>[];
    for (final contact in saved) {
      if (contact.id.isNotEmpty &&
          !visible.any((item) => item.id == contact.id)) {
        visible.add(contact);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FeatureHeader(
          title: 'Dodaj kontakt',
          subtitle: 'Wpisz kod parowania albo zeskanuj QR',
          actions: [
            IconButton.filledTonal(
              onPressed: onScanInvite,
              tooltip: 'Dodaj kontakt',
              icon: const Icon(Icons.person_add_alt_1),
            ),
            IconButton.filledTonal(
              onPressed: onShowInvite,
              tooltip: 'Mój kod parowania',
              icon: const Icon(Icons.qr_code_2),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (notice.isNotEmpty)
          StatusBanner(message: notice, color: context.statusTheme.success),
        if (error.isNotEmpty)
          StatusBanner(message: error, color: context.statusTheme.danger),
        TextField(
          controller: search,
          enabled: !busy,
          onSubmitted: (_) => onSearch(),
          keyboardType: TextInputType.number,
          maxLength: 9,
          inputFormatters: const [PairingCodeInputFormatter()],
          decoration: InputDecoration(
            counterText: '',
            hintText: 'Wpisz 8-cyfrowy kod parowania',
            prefixIcon: const Icon(Icons.password),
            suffixIcon: IconButton(
              onPressed: busy ? null : onSearch,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('Twój fingerprint', style: Theme.of(context).textTheme.labelLarge),
        Text(
          fingerprint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (showContactList) ...[
          const SizedBox(height: 12),
          Expanded(
            child: ContactListSection(
              title: 'Kontakty',
              contacts: visible,
              onSelect: onSelect,
              contactSubtitleBuilder: (contact) => contact.fingerprint.isEmpty
                  ? 'Fingerprint niedostępny'
                  : contact.fingerprint,
              contactTrailingBuilder: (contact) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (contact.devFixture != null)
                    const Chip(label: Text('DEV')),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
