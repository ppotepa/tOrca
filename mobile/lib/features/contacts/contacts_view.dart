import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/status_banner.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';

class ContactsView extends StatelessWidget {
  const ContactsView({
    super.key,
    required this.saved,
    required this.search,
    required this.onSearch,
    required this.onSelect,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.onUpdateContactSettings,
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
  final Future<void> Function(ContactRecord, String?, bool, bool)
  onUpdateContactSettings;
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
              icon: const ThemedIcon(Icons.person_add_alt_1),
            ),
            IconButton.filledTonal(
              onPressed: onShowInvite,
              tooltip: 'Mój kod parowania',
              icon: const ThemedIcon(Icons.qr_code_2),
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
            prefixIcon: const ThemedIcon(Icons.password),
            suffixIcon: IconButton(
              onPressed: busy ? null : onSearch,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const ThemedIcon(Icons.arrow_forward),
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
                  IconButton(
                    tooltip: 'Szczegóły kontaktu',
                    onPressed: () => _showContactDetails(context, contact),
                    icon: const ThemedIcon(Icons.info_outline),
                  ),
                  const ThemedIcon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showContactDetails(
    BuildContext context,
    ContactRecord contact,
  ) {
    final alias = TextEditingController(text: contact.localAlias ?? '');
    var muted = contact.muted;
    var blocked = contact.blocked;
    return showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(contact.displayName),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                contact.verified ? 'Kontakt zweryfikowany' : 'Brak weryfikacji',
              ),
              const SizedBox(height: 6),
              Text(
                'P2P przez Tor: ${_peerEndpointLabel(contact.peerEndpointStatus)}',
              ),
              Text(
                'Połączenie bezpośrednie: '
                '${_peerConnectionLabel(contact.peerConnectionStatus)}',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: alias,
                maxLength: 32,
                decoration: const InputDecoration(labelText: 'Lokalny alias'),
              ),
              ThemedSwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wycisz powiadomienia'),
                value: muted,
                onChanged: (value) => setDialogState(() => muted = value),
              ),
              ThemedSwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zablokuj kontakt'),
                subtitle: const Text('Nie odbieraj ani nie wysyłaj wiadomości'),
                value: blocked,
                onChanged: (value) => setDialogState(() => blocked = value),
              ),
              const SizedBox(height: 16),
              Text(
                'Installation ID',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              SelectableText(contact.id),
              const SizedBox(height: 12),
              Text(
                'Fingerprint',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              SelectableText(
                contact.fingerprint.isEmpty
                    ? 'Fingerprint niedostępny'
                    : contact.fingerprint,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () async {
                await onUpdateContactSettings(
                  contact,
                  alias.text.trim().isEmpty ? null : alias.text.trim(),
                  muted,
                  blocked,
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Zapisz'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Zamknij'),
            ),
          ],
        ),
      ),
    ).whenComplete(alias.dispose);
  }
}

String _peerEndpointLabel(PeerEndpointStatus status) => switch (status) {
  PeerEndpointStatus.verified => 'endpoint zweryfikowany',
  PeerEndpointStatus.pendingExchange => 'oczekuje na wymianę endpointu',
  PeerEndpointStatus.invalid => 'endpoint nieprawidłowy',
  PeerEndpointStatus.missing => 'endpoint niedostępny',
};

String _peerConnectionLabel(PeerConnectionStatus status) => switch (status) {
  PeerConnectionStatus.connected => 'połączono',
  PeerConnectionStatus.connecting => 'łączenie',
  PeerConnectionStatus.authenticating => 'uwierzytelnianie',
  PeerConnectionStatus.backoff => 'oczekiwanie na ponowienie',
  PeerConnectionStatus.offline => 'offline',
};
