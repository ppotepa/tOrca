import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_action_button.dart' show BusyIconButton;
import '../../shared/async/busy_surface.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/list_items.dart';
import '../../shared/widgets/status_banner.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';

class ContactsView extends ConsumerWidget {
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
  final VoidCallback onScanInvite;
  final VoidCallback onShowInvite;
  final Future<void> Function(
    ContactRecord,
    String?,
    bool,
    bool,
    ContactTransportPolicy,
  ) onUpdateContactSettings;
  final String fingerprint;
  final String ownInvite;
  final String error;
  final String notice;
  @Deprecated('Busy is derived from component-scoped operation providers.')
  final bool busy;
  final bool showContactList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactsLoad = ref.watch(
      uiOperationProvider(UiOperationKey.contactsLoad),
    );
    final submit = ref.watch(uiOperationProvider(UiOperationKey.pairingSubmit));
    final inviteCode = ref.watch(
      uiOperationProvider(UiOperationKey.inviteCodeLoad),
    );
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
            BusyIconButton(
              busy: submit.busy,
              onPressed: submit.busy ? null : onScanInvite,
              tooltip: 'Dodaj kontakt',
              icon: const ThemedIcon(Icons.person_add_alt_1),
            ),
            BusyIconButton(
              busy: inviteCode.busy,
              onPressed: inviteCode.busy ? null : onShowInvite,
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
          enabled: !submit.busy,
          onSubmitted: (_) {
            if (!submit.busy) onSearch();
          },
          keyboardType: TextInputType.number,
          maxLength: 9,
          inputFormatters: const [PairingCodeInputFormatter()],
          decoration: InputDecoration(
            counterText: '',
            hintText: submit.busy
                ? 'Przetwarzanie kodu…'
                : 'Wpisz 8-cyfrowy kod parowania',
            prefixIcon: const ThemedIcon(Icons.password),
            suffixIcon: BusyIconButton(
              busy: submit.busy,
              onPressed: submit.busy ? null : onSearch,
              tooltip: 'Wyślij kod',
              icon: const ThemedIcon(Icons.arrow_forward),
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
            child: BusySurface(
              state: contactsLoad,
              presentation: visible.isEmpty
                  ? BusyPresentation.replace
                  : BusyPresentation.overlay,
              label: 'Ładowanie kontaktów…',
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
                    PeerTransportIndicator(
                      connectionStatus: contact.peerConnectionStatus,
                      transportPolicy: contact.transportPolicy,
                      endpointStatus: contact.peerEndpointStatus,
                    ),
                    const SizedBox(width: 4),
                    if (contact.devFixture != null)
                      const Chip(label: Text('DEV')),
                    IconButton(
                      tooltip: 'Szczegóły kontaktu',
                      onPressed: () => _showContactDetails(context, ref, contact),
                      icon: const ThemedIcon(Icons.info_outline),
                    ),
                    const ThemedIcon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showContactDetails(
    BuildContext context,
    WidgetRef ref,
    ContactRecord contact,
  ) {
    final alias = TextEditingController(text: contact.localAlias ?? '');
    var muted = contact.muted;
    var transportPolicy = contact.transportPolicy;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) {
          final saveState = dialogRef.watch(
            uiOperationProvider(UiOperationKey.contactSettingsFor(contact.id)),
          );
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(contact.displayName),
              content: BusySurface(
                state: saveState,
                label: 'Zapisywanie ustawień…',
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Relacja ustanowiona przez zaakceptowany kod'),
                      const SizedBox(height: 6),
                      Text(
                        'P2P przez Tor: '
                        '${_peerEndpointLabel(contact.peerEndpointStatus)}',
                      ),
                      Text(
                        'Połączenie bezpośrednie: '
                        '${_peerConnectionLabel(contact.peerConnectionStatus)}',
                      ),
                      Text('Aktualna trasa: ${_effectiveRouteLabel(contact)}'),
                      if (kDebugMode) ...[
                        const SizedBox(height: 12),
                        const Divider(),
                        Text(
                          'Diagnostyka transportu DEV',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        _DiagnosticLine(
                          label: 'Polityka',
                          value: _transportPolicyLabel(contact.transportPolicy),
                        ),
                        _DiagnosticLine(
                          label: 'Efektywna trasa',
                          value: _effectiveRouteLabel(contact),
                        ),
                        _DiagnosticLine(
                          label: 'Stan endpointu',
                          value: _peerEndpointLabel(contact.peerEndpointStatus),
                        ),
                        _DiagnosticLine(
                          label: 'Stan sesji P2P',
                          value: _peerConnectionLabel(
                            contact.peerConnectionStatus,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      DropdownButtonFormField<ContactTransportPolicy>(
                        initialValue: transportPolicy,
                        decoration: const InputDecoration(
                          labelText: 'Polityka transportu',
                        ),
                        items: [
                          for (final policy in ContactTransportPolicy.values)
                            DropdownMenuItem(
                              value: policy,
                              child: Text(_transportPolicyLabel(policy)),
                            ),
                        ],
                        onChanged: saveState.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setDialogState(() => transportPolicy = value);
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: alias,
                        enabled: !saveState.busy,
                        maxLength: 32,
                        decoration: const InputDecoration(
                          labelText: 'Lokalny alias',
                        ),
                      ),
                      ThemedSwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Wycisz powiadomienia'),
                        value: muted,
                        onChanged: saveState.busy
                            ? null
                            : (value) => setDialogState(() => muted = value),
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
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        onPressed: saveState.busy
                            ? null
                            : () => _confirmRelationshipRemoval(
                                  context,
                                  dialogRef,
                                  contact,
                                  alias.text.trim().isEmpty
                                      ? null
                                      : alias.text.trim(),
                                  muted,
                                  transportPolicy,
                                ),
                        icon: const ThemedIcon(
                          Icons.person_remove_outlined,
                          size: 18,
                        ),
                        label: const Text('Zakończ relację'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                BusyActionButton(
                  busy: saveState.busy,
                  label: 'Zapisz',
                  busyLabel: 'Zapisywanie…',
                  onPressed: () async {
                    await onUpdateContactSettings(
                      contact,
                      alias.text.trim().isEmpty ? null : alias.text.trim(),
                      muted,
                      false,
                      transportPolicy,
                    );
                    final result = dialogRef.read(
                      uiOperationProvider(
                        UiOperationKey.contactSettingsFor(contact.id),
                      ),
                    );
                    if (context.mounted && !result.failed) {
                      Navigator.pop(context);
                    }
                  },
                ),
                TextButton(
                  onPressed: saveState.busy ? null : () => Navigator.pop(context),
                  child: const Text('Zamknij'),
                ),
              ],
            ),
          );
        },
      ),
    ).whenComplete(alias.dispose);
  }

  Future<void> _confirmRelationshipRemoval(
    BuildContext context,
    WidgetRef ref,
    ContactRecord contact,
    String? localAlias,
    bool muted,
    ContactTransportPolicy transportPolicy,
  ) async {
    var preserveHistory = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Zakończyć relację?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Kontakt ${contact.displayName} utraci możliwość wysyłania '
                'wiadomości. Ponowne dodanie będzie wymagało nowego kodu.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zachowaj historię na tym urządzeniu'),
                subtitle: const Text(
                  'Historia pozostanie lokalna i nie przywróci relacji.',
                ),
                value: preserveHistory,
                onChanged: (value) =>
                    setState(() => preserveHistory = value ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(confirmContext, false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(confirmContext, true),
              child: const Text('Zakończ relację'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'torchat.relationship.preserveHistory.${contact.id}',
      preserveHistory,
    );
    await onUpdateContactSettings(
      contact,
      localAlias,
      muted,
      true,
      transportPolicy,
    );
    final result = ref.read(
      uiOperationProvider(UiOperationKey.contactSettingsFor(contact.id)),
    );
    if (context.mounted && !result.failed) {
      Navigator.of(context).pop();
    }
  }
}

class _DiagnosticLine extends StatelessWidget {
  const _DiagnosticLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 126,
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

String _effectiveRouteLabel(ContactRecord contact) {
  if (contact.transportPolicy == ContactTransportPolicy.relayOnly) {
    return 'relay';
  }
  if (contact.peerConnectionStatus == PeerConnectionStatus.connected) {
    return 'P2P onion';
  }
  if (contact.transportPolicy ==
      ContactTransportPolicy.peerWithRelayFallback) {
    return 'relay fallback (P2P nieaktywne)';
  }
  return 'P2P oczekuje / offline';
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

String _transportPolicyLabel(ContactTransportPolicy policy) => switch (policy) {
      ContactTransportPolicy.peerOnly => 'Tylko P2P',
      ContactTransportPolicy.peerWithRelayFallback =>
        'P2P z fallbackiem relay',
      ContactTransportPolicy.relayOnly => 'Tylko relay',
    };
