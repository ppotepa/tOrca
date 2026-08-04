import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../app/app_controller.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/application_state/unread_summary.dart';
import '../../core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_avatar.dart';
import '../../shared/widgets/status_banner.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/status_localizer.dart';

class ContactsView extends ConsumerWidget {
  const ContactsView({
    super.key,
    required this.saved,
    required this.conversations,
    required this.search,
    required this.onSearch,
    required this.onSelect,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.onUpdateContactSettings,
    required this.fingerprint,
    required this.ownInvite,
    required this.canPair,
    required this.error,
    this.showContactList = true,
    this.pendingPairings = const [],
  });

  final List<ContactRecord> saved;
  final List<ConversationSummary> conversations;
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
  final bool canPair;
  final String error;
  final bool showContactList;
  final List<PairingItem> pendingPairings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final presenceStore = ref.watch(contactPresenceStoreProvider);
    final contactsLoad = ref.watch(
      uiOperationProvider(UiOperationKey.contactsLoad),
    );
    final submit = ref.watch(uiOperationProvider(UiOperationKey.pairingSubmit));
    final inviteCode = ref.watch(
      uiOperationProvider(UiOperationKey.inviteCodeLoad),
    );
    final unread = conversations.unreadSummary;
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
          title: l10n.contactsAddTitle,
          subtitle: l10n.contactsAddDescription,
          actions: [
            BusyIconButton(
              busy: submit.busy,
              onPressed: submit.busy ? null : onScanInvite,
              tooltip: l10n.contactsAddTitle,
              icon: const ThemedIcon(Icons.person_add_alt_1),
            ),
            BusyIconButton(
              busy: inviteCode.busy,
              onPressed: inviteCode.busy || !canPair ? null : onShowInvite,
              tooltip: l10n.myPairingCode,
              icon: const ThemedIcon(Icons.qr_code_2),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (error.isNotEmpty)
          StatusBanner(message: error, color: context.statusTheme.danger),
        Semantics(
          textField: true,
          label: l10n.pairingCodeLabel,
          hint: l10n.pairingCodeHint,
          child: TextField(
            controller: search,
            enabled: !submit.busy,
            onSubmitted: (_) {
              if (!submit.busy) onSearch();
            },
            keyboardType: TextInputType.text,
            maxLength: 80,
            inputFormatters: const [PairingCodeInputFormatter()],
            decoration: InputDecoration(
              counterText: '',
              hintText: submit.busy
                  ? l10n.processingPairingCode
                  : l10n.pairingCodeInputHint,
              prefixIcon: const ThemedIcon(Icons.password),
              suffixIcon: BusyIconButton(
                busy: submit.busy,
                onPressed: submit.busy ? null : onSearch,
                tooltip: l10n.sendCode,
                icon: const ThemedIcon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.yourFingerprint,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Semantics(
          label: l10n.yourFingerprintSemantics(fingerprint),
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
              label: l10n.loadingContacts,
              child: ContactListSection(
                title: l10n.contactsTitle,
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
                contactUnreadBuilder: (contact) =>
                    unread.messagesForContact(contact.id),
                contactSubtitleBuilder: (contact) {
                  final snapshot = presenceStore.snapshot(contact.id);
                  final status = switch (snapshot.availability) {
                    ContactAvailability.active => l10n.contactStatusActive,
                    ContactAvailability.idle => l10n.contactStatusIdle,
                    ContactAvailability.offline => l10n.contactStatusOffline,
                    ContactAvailability.unknown => l10n.contactStatusUnknown,
                    ContactAvailability.checking => l10n.contactStatusChecking,
                  };
                  final route = switch (contact.transportPolicy) {
                    ContactTransportPolicy.peerOnly => l10n.routeP2P,
                  };
                  return '$status · $route';
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
                    if (contact.devFixture != null)
                      const Chip(label: Text('DEV')),
                    IconButton(
                      tooltip: l10n.contactDetails,
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
                label: context.l10n.contactsSavingSettings,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.contactsEstablishedByPairingCode),
                      const SizedBox(height: 6),
                      Text(
                        '${context.l10n.contactsP2pThroughTor}: '
                        '${localizePeerEndpointStatus(context.l10n, contact.peerEndpointStatus)}',
                      ),
                      Text(
                        '${context.l10n.contactsDirectConnection}: '
                        '${localizePeerConnectionStatus(context.l10n, contact.peerConnectionStatus)}',
                      ),
                      Text(
                        '${context.l10n.contactsCurrentRoute}: '
                        '${localizeContactRoute(context.l10n, contact)}',
                      ),
                      Text(
                        '${context.l10n.contactsPresence}: '
                        '${localizeContactAvailability(context.l10n, presence.availability)}',
                      ),
                      Text(
                        '${context.l10n.contactsViewingConversation}: '
                        '${presence.isViewingConversation ? context.l10n.commonYes : context.l10n.commonNo}',
                      ),
                      Text(
                        '${context.l10n.contactsLastProbe}: '
                        '${presence.observedAt ?? context.l10n.contactsNoData}',
                      ),
                      if (presence.latencyMs != null)
                        Text(
                          '${context.l10n.contactsProbeLatency}: ${presence.latencyMs} ms',
                        ),
                      const SizedBox(height: 12),
                      const Divider(),
                      Text(
                        context.l10n.contactsP2pCapability,
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
                            return Text(
                              context.l10n.contactsCapabilityUnavailable,
                            );
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
                                    label: Text(context.l10n.contactsRotate),
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
                                    label: Text(context.l10n.contactsRevoke),
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
                          value: localizeTransportPolicy(
                            context.l10n,
                            contact.transportPolicy,
                          ),
                        ),
                        _DiagnosticLine(
                          label: 'Efektywna trasa',
                          value: localizeContactRoute(context.l10n, contact),
                        ),
                        _DiagnosticLine(
                          label: 'Stan endpointu',
                          value: localizePeerEndpointStatus(
                            context.l10n,
                            contact.peerEndpointStatus,
                          ),
                        ),
                        _DiagnosticLine(
                          label: 'Stan sesji P2P',
                          value: localizePeerConnectionStatus(
                            context.l10n,
                            contact.peerConnectionStatus,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future:
                              (dialogRef.read(clientRuntimeProvider) as dynamic)
                                  .listDeadLetters()
                                  .then(
                                    (value) => (value as List)
                                        .whereType<Map>()
                                        .map(
                                          (item) => item.map(
                                            (key, value) =>
                                                MapEntry(key.toString(), value),
                                          ),
                                        )
                                        .toList()
                                        .cast<Map<String, dynamic>>(),
                                  ),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const LinearProgressIndicator();
                            }
                            if (snapshot.hasError) {
                              return Text(
                                'Dead-letter niedostępny: ${snapshot.error}',
                              );
                            }
                            final records = snapshot.data ?? const [];
                            if (records.isEmpty) {
                              return Text(context.l10n.contactsNoDeadLetters);
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(context.l10n.contactsDeadLetterRetry),
                                for (final record in records)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${record['kind']}: ${record['id']}',
                                    ),
                                    subtitle: Text(
                                      record['lastError']?.toString() ??
                                          context.l10n.contactsNoError,
                                    ),
                                    trailing: IconButton(
                                      tooltip: context.l10n.commonRetry,
                                      icon: const ThemedIcon(Icons.refresh),
                                      onPressed: () async {
                                        await dialogRef
                                            .read(clientRuntimeProvider)
                                            .retryDeadLetter(
                                              record['kind'].toString(),
                                              record['id'].toString(),
                                            );
                                        if (context.mounted) {
                                          setDialogState(() {});
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 12),
                      DropdownButtonFormField<ContactTransportPolicy>(
                        initialValue: transportPolicy,
                        decoration: InputDecoration(
                          labelText: context.l10n.contactsTransportPolicy,
                        ),
                        items: [
                          for (final policy in ContactTransportPolicy.values)
                            DropdownMenuItem(
                              value: policy,
                              child: Text(
                                localizeTransportPolicy(context.l10n, policy),
                              ),
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
                        decoration: InputDecoration(
                          labelText: context.l10n.contactsLocalAlias,
                        ),
                      ),
                      ThemedSwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.l10n.contactEnableNotifications),
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
                        label: Text(context.l10n.contactEndRelationship),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                BusyActionButton(
                  busy: saveState.busy,
                  label: context.l10n.commonSave,
                  busyLabel: context.l10n.contactsSaving,
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
                  child: Text(context.l10n.commonClose),
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
          title: Text(context.l10n.relationshipEndTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.relationshipEndDescription(contact.displayName),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.relationshipKeepHistory),
                subtitle: Text(context.l10n.relationshipKeepHistoryDescription),
                value: preserveHistory,
                onChanged: (value) =>
                    setState(() => preserveHistory = value ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(confirmContext, false),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(confirmContext, true),
              child: Text(context.l10n.contactEndRelationship),
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
              title: Text(
                item.peer?.displayName ?? context.l10n.contactsNewContact,
              ),
              subtitle: Text(context.l10n.contactsWaitingForSecureConversation),
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
