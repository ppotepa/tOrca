import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../core/models/domain.dart';
import '../../../shared/widgets/contact_list_section.dart';
import '../../../shared/widgets/conversation_list_section.dart';
import '../../../shared/widgets/counter_badge.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/feature_header.dart';
import '../../../shared/widgets/identity_section.dart';
import '../../../shared/widgets/info_tile.dart';
import '../../../shared/widgets/section_card.dart';
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
    required this.onlineContacts,
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
  final Map<String, bool> onlineContacts;
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
  bool _inspectorOpen = false;
  bool _railExpanded = true;

  int get _unreadTotal => widget.conversations.totalUnread;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compactRail = constraints.maxWidth < 900 || !_railExpanded;
      final canShowInspector = constraints.maxWidth >= 1320;
      final selected = widget.selectedContact;
      final showInspector =
          canShowInspector && _inspectorOpen && selected != null;

      return Row(
        children: [
          SizedBox(
            width: compactRail ? 68 : 116,
            child: _CompactNavigationRail(
              compact: compactRail,
              tab: widget.tab,
              nickname: widget.nickname,
              unreadTotal: _unreadTotal,
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
                      selectedConversation: widget.selectedConversation,
                      onOpenConversation: widget.onOpenConversation,
                    )
                  : _ContactSidebar(
                      contacts: widget.contacts,
                      onlineContacts: widget.onlineContacts,
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
                        if (selected != null)
                          Positioned(
                            top: 10,
                            right: 10,
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

class _CompactNavigationRail extends StatelessWidget {
  const _CompactNavigationRail({
    required this.compact,
    required this.tab,
    required this.nickname,
    required this.unreadTotal,
    required this.onTab,
    required this.onAccount,
    required this.onSettings,
    required this.onToggle,
  });

  final bool compact;
  final MobileTab tab;
  final String nickname;
  final int unreadTotal;
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
              badge: unreadTotal,
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
              CounterBadge(count: badge, child: ThemedIcon(icon, size: 20)),
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

enum _ConversationMode { chats, groups }

class _ConversationSidebar extends StatefulWidget {
  const _ConversationSidebar({
    required this.conversations,
    required this.contacts,
    required this.selectedConversation,
    required this.onOpenConversation,
  });

  final List<ConversationSummary> conversations;
  final List<ContactRecord> contacts;
  final String? selectedConversation;
  final ValueChanged<String> onOpenConversation;

  @override
  State<_ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<_ConversationSidebar> {
  final _search = TextEditingController();
  _ConversationMode _mode = _ConversationMode.chats;

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
            title: _mode == _ConversationMode.chats ? 'Czaty' : 'Grupy',
            subtitle: _mode == _ConversationMode.chats
                ? '${widget.conversations.length} rozmów'
                : 'Osobna przestrzeń grupowa',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Szukaj…',
              prefixIcon: ThemedIcon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<_ConversationMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _ConversationMode.chats,
                label: Text('Czaty'),
                icon: ThemedIcon(Icons.chat_bubble_outline, size: 16),
              ),
              ButtonSegment(
                value: _ConversationMode.groups,
                label: Text('Grupy'),
                icon: ThemedIcon(Icons.groups_outlined, size: 16),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value.first),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: _mode == _ConversationMode.groups
                  ? const EmptyState(
                      key: ValueKey('groups-empty'),
                      icon: Icons.groups_outlined,
                      message:
                          'Grupy będą wyświetlane w osobnej sekcji.\nNie mieszamy ich ze zwykłymi czatami.',
                    )
                  : ConversationListSection(
                      key: const ValueKey('chat-list'),
                      title: 'Czaty',
                      conversations: _filtered,
                      contacts: widget.contacts,
                      selectedConversation: widget.selectedConversation,
                      onOpenConversation: widget.onOpenConversation,
                      asCard: false,
                      showHeader: false,
                      emptyMessage: _search.text.trim().isEmpty
                          ? 'Nie masz jeszcze rozmów.'
                          : 'Brak rozmów pasujących do wyszukiwania.',
                    ),
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
    required this.onlineContacts,
    required this.onSelect,
  });

  final List<ContactRecord> contacts;
  final Map<String, bool> onlineContacts;
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
            _ContactFilter.online => widget.onlineContacts[contact.id] == true,
            _ContactFilter.p2p =>
              contact.transportPolicy != ContactTransportPolicy.relayOnly,
          };
          return matchesQuery && matchesFilter;
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
            title: 'Kontakty',
            subtitle: '${widget.contacts.length} zapisanych',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Szukaj kontaktów…',
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
                label: 'Wszyscy',
                selected: _filter == _ContactFilter.all,
                onSelected: () => setState(() => _filter = _ContactFilter.all),
              ),
              _FilterChip(
                label: 'Online',
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
              title: 'Kontakty',
              contacts: _filtered,
              onSelect: widget.onSelect,
              asCard: false,
              showHeader: false,
              emptyMessage: 'Brak kontaktów dla wybranego filtra.',
              contactSubtitleBuilder: (contact) {
                final online = widget.onlineContacts[contact.id] == true;
                final route = switch (contact.transportPolicy) {
                  ContactTransportPolicy.relayOnly => 'Tor relay',
                  ContactTransportPolicy.peerWithRelayFallback =>
                    contact.peerConnectionStatus ==
                            PeerConnectionStatus.connected
                        ? 'Tor P2P'
                        : 'Tor P2P + relay fallback',
                  ContactTransportPolicy.peerOnly => 'Tor P2P',
                };
                return '${online ? 'online' : 'offline'} · $route';
              },
              contactTrailingBuilder: (contact) =>
                  const ThemedIcon(Icons.chevron_right, size: 18),
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
    required this.onVerify,
    required this.onClose,
    required this.onBack,
  });

  final ContactRecord contact;
  final ValueChanged<String> onVerify;
  final VoidCallback onClose;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      color: shell.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: shell.border, width: shell.borderWidth),
        ),
      ),
      child: ListView(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Zamknij szczegóły',
              onPressed: onClose,
              icon: const ThemedIcon(Icons.close, size: 18),
            ),
          ),
          IdentitySection(
            title: 'KONTAKT',
            name: contact.displayName,
            subtitle: contact.verified
                ? 'Tożsamość zweryfikowana'
                : 'Tożsamość niezweryfikowana',
            fingerprint: contact.fingerprint,
          ),
          const SizedBox(height: 14),
          if (!contact.verified)
            FilledButton.icon(
              onPressed: () => onVerify(contact.id),
              icon: const ThemedIcon(Icons.verified_user_outlined, size: 17),
              label: const Text('Zweryfikuj tożsamość'),
            ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'POŁĄCZENIE',
            child: Column(
              children: [
                InfoTile(
                  title: 'Trasa',
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
                  title: 'Endpoint',
                  subtitle: contact.peerEndpointStatus.name,
                ),
                InfoTile(
                  title: 'Polityka',
                  subtitle: contact.transportPolicy.name,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'INFORMACJE',
            child: Column(
              children: [
                InfoTile(title: 'Installation ID', subtitle: contact.id),
                InfoTile(
                  title: 'Ostatnie P2P',
                  subtitle:
                      contact.lastPeerConnectedAt?.trim().isNotEmpty == true
                      ? contact.lastPeerConnectedAt!
                      : 'Brak zapisanej sesji',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onBack,
            icon: const ThemedIcon(Icons.close_fullscreen, size: 17),
            label: const Text('Zamknij rozmowę'),
          ),
        ],
      ),
    );
  }
}

String _inspectorRouteLabel(ContactRecord contact) =>
    switch (contact.transportPolicy) {
      ContactTransportPolicy.relayOnly => 'Przez Tor relay',
      ContactTransportPolicy.peerWithRelayFallback =>
        contact.peerConnectionStatus == PeerConnectionStatus.connected
            ? 'Bezposrednio przez Tor P2P'
            : 'P2P / awaryjny relay',
      ContactTransportPolicy.peerOnly => 'Przez Tor P2P / oczekiwanie na peer',
    };
