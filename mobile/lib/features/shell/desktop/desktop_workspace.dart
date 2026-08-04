import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../core/application_state/unread_summary.dart';
import '../../../core/models/domain.dart';
import '../../../core/presence/contact_presence_snapshot.dart';
import '../../../core/presence/contact_presence_store.dart';
import '../../../shared/widgets/contact_list_section.dart';
import '../../../shared/widgets/conversation_list_section.dart';
import '../../../shared/widgets/counter_badge.dart';
import '../../../shared/widgets/feature_header.dart';
import '../../../shared/widgets/identity_section.dart';
import '../../../shared/widgets/info_tile.dart';
import '../../../shared/widgets/identity_avatar.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/formatters/message_timestamps.dart';
import '../../../locales/presentation/app_localizations_x.dart';
import 'resizable_split_pane.dart';

class DesktopWorkspace extends StatefulWidget {
  const DesktopWorkspace({
    super.key,
    required this.tab,
    required this.nickname,
    required this.contacts,
    required this.conversations,
    required this.selectedConversation,
    required this.selectedContact,
    this.presenceStore,
    required this.content,
    required this.onTab,
    required this.onOpenConversation,
    required this.onStartConversation,
    required this.onVerifyContact,
    required this.onBack,
    required this.onAccount,
    required this.onSettings,
  });

  final MobileTab tab;
  final String nickname;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final String? selectedConversation;
  final ContactRecord? selectedContact;
  final ContactPresenceStore? presenceStore;
  final Widget content;
  final ValueChanged<MobileTab> onTab;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;
  final ValueChanged<String> onVerifyContact;
  final VoidCallback onBack;
  final VoidCallback onAccount;
  final VoidCallback onSettings;

  @override
  State<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<DesktopWorkspace> {
  late final ContactPresenceStore _presenceStore =
      widget.presenceStore ?? ContactPresenceStore();
  // Keep the inspector visible for an active conversation by default.  It is
  // still user-toggleable from the header, but the desktop layout must expose
  // delivery/connection details without requiring a hidden discovery action.
  bool _inspectorOpen = true;
  bool _railExpanded = true;

  int get _unreadContactCount =>
      widget.conversations.unreadSummary.contactsWithUnread;

  @override
  Widget build(BuildContext context) {
    final presence = _presenceStore;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactRail = constraints.maxWidth < 900 || !_railExpanded;
        // Keep the details panel available on ordinary 1080p desktop windows;
        // the previous 1320 px gate silently removed it on common laptop
        // resolutions.  Below this width the conversation remains usable in a
        // single-column layout and the header toggle can still be used when the
        // window grows again.
        final canShowInspector = constraints.maxWidth >= 1280;
        final selected = widget.selectedContact;
        final showInspector =
            canShowInspector && _inspectorOpen && selected != null;

        return Row(
          children: [
            SizedBox(
              // The expanded rail needs enough room for the labels and their
              // icons.  A 116 px rail looked fine at large sizes but clipped
              // "Kontakty" and "Ustawienia" as soon as the workspace became
              // narrower.  Compact mode remains icon-only for truly narrow
              // windows.
              width: compactRail ? 68 : 164,
              child: _CompactNavigationRail(
                compact: compactRail,
                tab: widget.tab,
                nickname: widget.nickname,
                unreadContactCount: _unreadContactCount,
                onTab: widget.onTab,
                onAccount: widget.onAccount,
                onSettings: widget.onSettings,
                onToggle: () => setState(() => _railExpanded = !_railExpanded),
              ),
            ),
            Expanded(
              child: ResizableSplitPane(
                sidebar: widget.tab == MobileTab.chats
                    ? _ConversationSidebar(
                        conversations: widget.conversations,
                        contacts: widget.contacts,
                        presenceStore: _presenceStore,
                        selectedConversation: widget.selectedConversation,
                        onOpenConversation: widget.onOpenConversation,
                      )
                    : _ContactSidebar(
                        contacts: widget.contacts,
                        conversations: widget.conversations,
                        presenceStore: _presenceStore,
                        onSelect: widget.onStartConversation,
                      ),
                content: Row(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: widget.tab == MobileTab.chats
                                  ? widget.content
                                  : Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: widget.content,
                                    ),
                            ),
                          ),
                          if (selected != null && canShowInspector)
                            Positioned(
                              // Keep the inspector affordance out of the
                              // conversation AppBar action row. It behaves as a
                              // floating side tab below the 68 px header.
                              top: 78,
                              right: 12,
                              child: Tooltip(
                                message: showInspector
                                    ? 'Ukryj szczegóły'
                                    : 'Pokaż szczegóły',
                                child: IconButton.filledTonal(
                                  onPressed: () => setState(
                                    () => _inspectorOpen = !_inspectorOpen,
                                  ),
                                  icon: ThemedIcon(
                                    showInspector
                                        ? Icons.expand_less
                                        : Icons.info_outline,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showInspector)
                      SizedBox(
                        width: 320,
                        child: _ConversationInspector(
                          contact: selected,
                          presence: presence.snapshot(selected.id),
                          onVerify: widget.onVerifyContact,
                          onClose: () => setState(() => _inspectorOpen = false),
                          onBack: widget.onBack,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CompactNavigationRail extends StatelessWidget {
  const _CompactNavigationRail({
    required this.compact,
    required this.tab,
    required this.nickname,
    required this.unreadContactCount,
    required this.onTab,
    required this.onAccount,
    required this.onSettings,
    required this.onToggle,
  });

  final bool compact;
  final MobileTab tab;
  final String nickname;
  final int unreadContactCount;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onAccount;
  final VoidCallback onSettings;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Material(
      color: shell.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: shell.border, width: shell.borderWidth),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            _RailItem(
              compact: compact,
              icon: compact ? Icons.menu : Icons.menu_open,
              label: compact ? 'Rozwiń nawigację' : 'Zwiń nawigację',
              onPressed: onToggle,
            ),
            _RailItem(
              compact: compact,
              selected: tab == MobileTab.chats,
              icon: Icons.chat_bubble_outline,
              label: 'Czaty',
              badge: unreadContactCount,
              onPressed: () => onTab(MobileTab.chats),
            ),
            _RailItem(
              compact: compact,
              selected: tab == MobileTab.contacts,
              icon: Icons.people_outline,
              label: 'Kontakty',
              onPressed: () => onTab(MobileTab.contacts),
            ),
            const Spacer(),
            Divider(color: shell.border, height: 1),
            _RailItem(
              compact: compact,
              icon: Icons.person_outline,
              label: nickname.trim().isEmpty ? 'Konto' : nickname,
              onPressed: onAccount,
            ),
            _RailItem(
              compact: compact,
              icon: Icons.settings_outlined,
              label: 'Ustawienia',
              onPressed: onSettings,
            ),
            Divider(color: shell.border, height: 1),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 12,
                vertical: 14,
              ),
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  const ThemedIcon(Icons.shield_outlined, size: 21),
                  if (!compact) ...[
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        'TorChat',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.compact,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.badge = 0,
  });

  final bool compact;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final child = Container(
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? shell.selectedNavigationBackground : null,
        border: selected
            ? Border(
                left: BorderSide(
                  color: shell.selectedNavigationBorder,
                  width: shell.borderWidth * 2,
                ),
              )
            : null,
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(10),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              CounterBadge(
                count: badge,
                semanticLabel:
                    '$badge kontaktów z nieprzeczytanymi wiadomościami',
                child: ThemedIcon(icon, size: 20),
              ),
              if (!compact) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: child) : child;
  }
}

class _ConversationSidebar extends StatefulWidget {
  const _ConversationSidebar({
    required this.conversations,
    required this.contacts,
    required this.presenceStore,
    required this.selectedConversation,
    required this.onOpenConversation,
  });

  final List<ConversationSummary> conversations;
  final List<ContactRecord> contacts;
  final ContactPresenceStore presenceStore;
  final String? selectedConversation;
  final ValueChanged<String> onOpenConversation;

  @override
  State<_ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<_ConversationSidebar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ConversationSummary> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.conversations;
    return widget.conversations
        .where((conversation) {
          var contactName = '';
          for (final contact in widget.contacts) {
            if (contact.id == conversation.contactId) {
              contactName = contact.displayName.toLowerCase();
              break;
            }
          }
          return contactName.contains(query) ||
              conversation.preview.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      color: shell.surface,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FeatureHeader(
            title: context.l10n.desktopChats,
            subtitle: context.l10n.desktopConversationCount(
              widget.conversations.length,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.l10n.desktopSearch,
              prefixIcon: ThemedIcon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ConversationListSection(
              key: const ValueKey('chat-list'),
              title: context.l10n.desktopChats,
              conversations: _filtered,
              contacts: widget.contacts,
              selectedConversation: widget.selectedConversation,
              onOpenConversation: widget.onOpenConversation,
              asCard: false,
              showHeader: false,
              emptyMessage: _search.text.trim().isEmpty
                  ? context.l10n.desktopNoConversations
                  : context.l10n.desktopNoConversationMatches,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ContactFilter { all, online, p2p }

class _ContactSidebar extends StatefulWidget {
  const _ContactSidebar({
    required this.contacts,
    required this.conversations,
    required this.presenceStore,
    required this.onSelect,
  });

  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final ContactPresenceStore presenceStore;
  final ValueChanged<ContactRecord> onSelect;

  @override
  State<_ContactSidebar> createState() => _ContactSidebarState();
}

class _ContactSidebarState extends State<_ContactSidebar> {
  final _search = TextEditingController();
  _ContactFilter _filter = _ContactFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ContactRecord> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return widget.contacts
        .where((contact) {
          final matchesQuery =
              query.isEmpty ||
              contact.displayName.toLowerCase().contains(query) ||
              contact.fingerprint.toLowerCase().contains(query);
          final matchesFilter = switch (_filter) {
            _ContactFilter.all => true,
            _ContactFilter.online =>
              widget.presenceStore.snapshot(contact.id).availability ==
                  ContactAvailability.active,
            _ContactFilter.p2p => true,
          };
          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final unread = widget.conversations.unreadSummary;
    return Container(
      color: shell.surface,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FeatureHeader(
            title: context.l10n.desktopContacts,
            subtitle: context.l10n.desktopContactCount(widget.contacts.length),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.l10n.desktopSearchContacts,
              prefixIcon: ThemedIcon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _FilterChip(
                label: context.l10n.desktopAll,
                selected: _filter == _ContactFilter.all,
                onSelected: () => setState(() => _filter = _ContactFilter.all),
              ),
              _FilterChip(
                label: context.l10n.desktopOnline,
                selected: _filter == _ContactFilter.online,
                onSelected: () =>
                    setState(() => _filter = _ContactFilter.online),
              ),
              _FilterChip(
                label: 'P2P',
                selected: _filter == _ContactFilter.p2p,
                onSelected: () => setState(() => _filter = _ContactFilter.p2p),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ContactListSection(
              title: context.l10n.desktopContacts,
              contacts: _filtered,
              onSelect: widget.onSelect,
              asCard: false,
              showHeader: false,
              emptyMessage: context.l10n.desktopFilteredContactsEmpty,
              contactSubtitleBuilder: (contact) {
                final availability = widget.presenceStore
                    .snapshot(contact.id)
                    .availability;
                final presenceLabel = _availabilityLabel(availability);
                final route = switch (contact.transportPolicy) {
                  ContactTransportPolicy.peerOnly => 'Tor P2P',
                };
                return '$presenceLabel · $route';
              },
              contactTrailingBuilder: (contact) =>
                  const ThemedIcon(Icons.chevron_right, size: 18),
              contactUnreadBuilder: (contact) =>
                  unread.messagesForContact(contact.id),
              contactActivityBuilder: (contact) => switch (widget.presenceStore
                  .snapshot(contact.id)
                  .availability) {
                ContactAvailability.active => ContactActivityVisualState.online,
                ContactAvailability.idle => ContactActivityVisualState.away,
                ContactAvailability.checking =>
                  ContactActivityVisualState.typing,
                ContactAvailability.offline =>
                  ContactActivityVisualState.offline,
                ContactAvailability.unknown =>
                  ContactActivityVisualState.unknown,
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    onSelected: (_) => onSelected(),
  );
}

class _ConversationInspector extends StatelessWidget {
  const _ConversationInspector({
    required this.contact,
    required this.presence,
    required this.onVerify,
    required this.onClose,
    required this.onBack,
  });

  final ContactRecord contact;
  final ContactPresenceSnapshot presence;
  final ValueChanged<String> onVerify;
  final VoidCallback onClose;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: shell.surface,
        border: Border(
          left: BorderSide(color: shell.border, width: shell.borderWidth),
        ),
      ),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.desktopContactDetails,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              SizedBox.square(
                dimension: 40,
                child: IconButton(
                  tooltip: context.l10n.desktopCloseDetails,
                  onPressed: onClose,
                  icon: const ThemedIcon(Icons.close, size: 19),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          IdentitySection(
            title: context.l10n.desktopContactSection,
            name: contact.displayName,
            subtitle: contact.verified
                ? context.l10n.desktopIdentityVerified
                : context.l10n.desktopIdentityUnverified,
            fingerprint: contact.fingerprint,
          ),
          const SizedBox(height: 14),
          if (!contact.verified)
            FilledButton.icon(
              onPressed: () => onVerify(contact.id),
              icon: const ThemedIcon(Icons.verified_user_outlined, size: 17),
              label: Text(context.l10n.desktopVerifyIdentity),
            ),
          const SizedBox(height: 12),
          SectionCard(
            title: context.l10n.desktopPresenceSection,
            child: Column(
              children: [
                InfoTile(
                  title: context.l10n.desktopStatus,
                  subtitle: _availabilityLabel(presence.availability),
                ),
                InfoTile(
                  title: context.l10n.desktopLastSeen,
                  subtitle: formatRelativeTimestamp(
                    presence.lastSeenAt?.toString(),
                    context.l10n,
                    empty: 'Brak danych',
                  ),
                ),
                InfoTile(
                  title: context.l10n.desktopObserved,
                  subtitle: formatRelativeTimestamp(
                    presence.observedAt?.toString(),
                    context.l10n,
                    empty: 'Brak danych',
                  ),
                ),
                InfoTile(
                  title: context.l10n.desktopObservationExpiry,
                  subtitle: formatRelativeTimestamp(
                    presence.expiresAt?.toString(),
                    context.l10n,
                    empty: 'Brak expiry',
                  ),
                ),
                InfoTile(
                  title: context.l10n.desktopConversationFocus,
                  subtitle: presence.isViewingConversation
                      ? context.l10n.commonYes
                      : context.l10n.commonNo,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: context.l10n.desktopConnectionSection,
            child: Column(
              children: [
                InfoTile(
                  title: context.l10n.desktopP2pConnection,
                  subtitle: _peerLinkLabel(presence.peerLink),
                ),
                InfoTile(
                  title: context.l10n.desktopProbeLatency,
                  subtitle: presence.latencyMs == null
                      ? 'Brak danych'
                      : '${presence.latencyMs} ms',
                ),
                InfoTile(
                  title: context.l10n.desktopNextProbe,
                  subtitle: presence.retryInMs == null
                      ? 'Brak zaplanowanego retry'
                      : 'Za ${presence.retryInMs} ms',
                ),
                InfoTile(
                  title: context.l10n.desktopLastP2pConnection,
                  subtitle: formatRelativeTimestamp(
                    presence.lastPeerConnectedAt?.toString(),
                    context.l10n,
                    empty: 'Brak danych',
                  ),
                ),
                InfoTile(
                  title: context.l10n.desktopRoute,
                  subtitle: _inspectorRouteLabel(contact),
                  /*
                      contact.peerConnectionStatus ==
                          PeerConnectionStatus.connected
                      ? 'Bezpośrednio przez Tor P2P'
                      : 'Przez Tor relay / oczekiwanie na P2P',
                ),
                  */
                ),
                InfoTile(
                  title: context.l10n.desktopEndpoint,
                  subtitle: _endpointLabel(contact.peerEndpointStatus),
                ),
                InfoTile(
                  title: context.l10n.desktopPolicy,
                  subtitle: _policyLabel(contact.transportPolicy),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: context.l10n.desktopInformationSection,
            child: Column(
              children: [
                InfoTile(
                  title: context.l10n.desktopInstallationId,
                  subtitle: _compactIdentifier(contact.id),
                ),
                InfoTile(
                  title: context.l10n.desktopLastP2p,
                  subtitle: formatRelativeTimestamp(
                    contact.lastPeerConnectedAt,
                    context.l10n,
                    empty: 'Brak zapisanej sesji',
                  ),
                ),
                InfoTile(
                  title: context.l10n.desktopLastSeen,
                  subtitle: formatRelativeTimestamp(
                    contact.lastSeenAt,
                    context.l10n,
                    empty: 'Brak danych',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onBack,
            icon: const ThemedIcon(Icons.arrow_back, size: 17),
            label: Text(context.l10n.desktopBackToConversations),
          ),
        ],
      ),
    );
  }
}

String _inspectorRouteLabel(ContactRecord contact) =>
    switch (contact.transportPolicy) {
      ContactTransportPolicy.peerOnly => 'Przez Tor P2P / oczekiwanie na peer',
    };

String _availabilityLabel(ContactAvailability value) => switch (value) {
  ContactAvailability.active => 'Aktywny w aplikacji',
  ContactAvailability.idle => 'Bezczynny',
  ContactAvailability.checking => 'Sprawdzanie',
  ContactAvailability.offline => 'Offline',
  ContactAvailability.unknown => 'Status nieznany',
};

String _peerLinkLabel(ContactPeerLink value) => switch (value) {
  ContactPeerLink.connected => 'Connected',
  ContactPeerLink.connecting => 'Connecting',
  ContactPeerLink.authenticating => 'Authenticating',
  ContactPeerLink.backoff => 'Backoff',
  ContactPeerLink.offline => 'Offline',
  ContactPeerLink.unknown => 'Unknown',
};

String _endpointLabel(PeerEndpointStatus status) => switch (status) {
  PeerEndpointStatus.verified => 'Zweryfikowany',
  PeerEndpointStatus.pendingExchange => 'Oczekuje na wymianę',
  PeerEndpointStatus.missing => 'Niedostępny',
  PeerEndpointStatus.invalid => 'Nieprawidłowy',
};

String _policyLabel(ContactTransportPolicy policy) => switch (policy) {
  ContactTransportPolicy.peerOnly => 'Tylko P2P',
};

String _compactIdentifier(String value) {
  final clean = value.trim();
  if (clean.length <= 20) return clean;
  return '${clean.substring(0, 10)}…${clean.substring(clean.length - 8)}';
}
