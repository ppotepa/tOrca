import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../app/app_controller.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_avatar.dart';
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
    this.showContactList = true,
    this.onlineContacts = const {},
    this.idleContacts = const {},
    this.pendingPairings = const [],
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
  )
  onUpdateContactSettings;
  final String fingerprint;
  final String ownInvite;
  final String error;
  final bool showContactList;
  final Map<String, bool> onlineContacts;
  final Map<String, bool> idleContacts;
  final List<PairingItem> pendingPairings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presenceStore = ref.watch(contactPresenceStoreProvider);
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
        if (error.isNotEmpty)
          StatusBanner(message: error, color: context.statusTheme.danger),
        Semantics(
          textField: true,
          label: 'Kod parowania',
          hint: 'Wpisz ośmiocyfrowy kod kontaktu',
          child: TextField(
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
        ),
        const SizedBox(height: 8),
        Text('Twój fingerprint', style: Theme.of(context).textTheme.labelLarge),
        Semantics(
          label: 'Twój fingerprint: $fingerprint',
          child: ExcludeSemantics(
            child: Text(
              fingerprint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        if (showContactList) ...[
          const SizedBox(height: 12),
          if (pendingPairings.isNotEmpty)
            _PendingPairingSection(items: pendingPairings),
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
                onDetails: (contact) =>
                    _showContactDetails(context, ref, contact),
                onToggleMute: (contact) => onUpdateContactSettings(
                  contact,
                  contact.localAlias,
                  !contact.muted,
                  false,
                  contact.transportPolicy,
                ),
                onRemove: (contact) => _confirmRelationshipRemoval(
                  context,
                  ref,
                  contact,
                  contact.localAlias,
                  contact.muted,
                  contact.transportPolicy,
                  closeParentOnSuccess: false,
                ),
                contactSubtitleBuilder: (contact) {
                  final snapshot = presenceStore.snapshot(contact.id);
                  final status = switch (snapshot.availability) {
                    ContactAvailability.active => 'aktywny w aplikacji',
                    ContactAvailability.idle => 'bezczynny',
                    ContactAvailability.offline => 'offline',
                    ContactAvailability.unknown => 'status nieznany',
                    ContactAvailability.checking => 'sprawdzanie',
                  };
                  return contact.fingerprint.isEmpty
                      ? status
                      : '$status · ${contact.fingerprint}';
                },
                contactActivityBuilder: (contact) {
                  final availability = presenceStore
                      .snapshot(contact.id)
                      .availability;
                  return switch (availability) {
                    ContactAvailability.active =>
                      ContactActivityVisualState.online,
                    ContactAvailability.idle => ContactActivityVisualState.away,
                    ContactAvailability.offline =>
                      ContactActivityVisualState.offline,
                    _ => ContactActivityVisualState.unknown,
                  };
                },
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
                      onPressed: () =>
                          _showContactDetails(context, ref, contact),
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
    var capabilityFuture = ref
        .read(clientRuntimeProvider)
        .contactEndpointCapability(contact.id);
    var capabilityBusy = false;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) {
          final saveState = dialogRef.watch(
            uiOperationProvider(UiOperationKey.contactSettingsFor(contact.id)),
          );
          final presence = dialogRef
              .watch(contactPresenceStoreProvider)
              .snapshot(contact.id);
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
                      Text(
                        'Obecność: ${_availabilityLabel(presence.availability)}',
                      ),
                      Text(
                        'Ogląda rozmowę: ${presence.isViewingConversation ? 'tak' : 'nie'}',
                      ),
                      Text(
                        'Ostatni probe: ${presence.observedAt ?? 'brak danych'}',
                      ),
                      if (presence.latencyMs != null)
                        Text('Latency probe: ${presence.latencyMs} ms'),
                      const SizedBox(height: 12),
                      const Divider(),
                      Text(
                        'Capability endpointu P2P',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      FutureBuilder<ContactEndpointCapabilityStatus>(
                        future: capabilityFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const LinearProgressIndicator();
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return const Text('Status capability niedostępny');
                          }
                          final capability = snapshot.data!;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Stan: ${capability.status.name.toUpperCase()}',
                              ),
                              Text('ID: ${capability.capabilityId}'),
                              Text('Sekwencja: ${capability.sequence}'),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: capabilityBusy
                                        ? null
                                        : () async {
                                            setDialogState(
                                              () => capabilityBusy = true,
                                            );
                                            try {
                                              await ref
                                                  .read(clientRuntimeProvider)
                                                  .rotateContactEndpointCapability(
                                                    contact.id,
                                                  );
                                              capabilityFuture = ref
                                                  .read(clientRuntimeProvider)
                                                  .contactEndpointCapability(
                                                    contact.id,
                                                  );
                                            } finally {
                                              if (context.mounted) {
                                                setDialogState(
                                                  () => capabilityBusy = false,
                                                );
                                              }
                                            }
                                          },
                                    icon: const ThemedIcon(Icons.refresh),
                                    label: const Text('Rotuj'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                        capabilityBusy ||
                                            capability.status ==
                                                CapabilityStatus.revoked
                                        ? null
                                        : () async {
                                            setDialogState(
                                              () => capabilityBusy = true,
                                            );
                                            try {
                                              await ref
                                                  .read(clientRuntimeProvider)
                                                  .revokeContactEndpointCapability(
                                                    contact.id,
                                                  );
                                              capabilityFuture = ref
                                                  .read(clientRuntimeProvider)
                                                  .contactEndpointCapability(
                                                    contact.id,
                                                  );
                                            } finally {
                                              if (context.mounted) {
                                                setDialogState(
                                                  () => capabilityBusy = false,
                                                );
                                              }
                                            }
                                          },
                                    icon: const ThemedIcon(Icons.block),
                                    label: const Text('Unieważnij'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
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
                  onPressed: saveState.busy
                      ? null
                      : () => Navigator.pop(context),
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
    ContactTransportPolicy transportPolicy, {
    bool closeParentOnSuccess = true,
  }) async {
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
    if (!context.mounted || result.failed) return;
    if (closeParentOnSuccess) {
      Navigator.of(context).pop();
    } else {
      ref
          .read(uiNotificationCenterProvider.notifier)
          .showSuccess(
            'Relacja z ${contact.displayName} została zakończona.',
            deduplicationKey: 'relationship-removed:${contact.id}',
          );
    }
  }
}

class _PendingPairingSection extends StatelessWidget {
  const _PendingPairingSection({required this.items});

  final List<PairingItem> items;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Oczekujące parowania',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        ...items.map(
          (item) => Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: const ThemedIcon(Icons.hourglass_top),
              title: Text(item.peer?.displayName ?? 'Nowy kontakt'),
              subtitle: const Text(
                'Oczekiwanie na ustanowienie szyfrowanej rozmowy',
              ),
            ),
          ),
        ),
      ],
    ),
  );
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
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
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
  if (contact.transportPolicy == ContactTransportPolicy.peerWithRelayFallback) {
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

String _availabilityLabel(ContactAvailability value) => switch (value) {
  ContactAvailability.active => 'aktywny w aplikacji',
  ContactAvailability.idle => 'bezczynny',
  ContactAvailability.checking => 'sprawdzanie',
  ContactAvailability.offline => 'offline',
  ContactAvailability.unknown => 'status nieznany',
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
  ContactTransportPolicy.peerWithRelayFallback => 'P2P z fallbackiem relay',
  ContactTransportPolicy.relayOnly => 'Tylko relay',
};
