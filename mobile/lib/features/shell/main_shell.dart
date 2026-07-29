import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/widgets/action_status_strip.dart';
import '../../shared/widgets/contact_list_section.dart';
import '../../shared/widgets/conversation_list_section.dart';
import '../../shared/widgets/counter_badge.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_section.dart';
import '../../shared/widgets/info_list_section.dart';
import '../../shared/widgets/info_tile.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/tor_status_bar.dart';
import '../chats/chats_view.dart';
import '../contacts/contacts_view.dart';

class MainShell extends StatelessWidget {
  const MainShell({
    super.key,
    required this.tab,
    required this.nickname,
    required this.fingerprint,
    required this.ownInvite,
    required this.status,
    required this.phase,
    required this.latencyMs,
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.selectedConversation,
    required this.selectedContact,
    required this.search,
    required this.composer,
    required this.error,
    required this.notice,
    required this.action,
    required this.onTab,
    required this.onSearch,
    required this.onOpenConversation,
    required this.onStartConversation,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.onSend,
    required this.onTypingChanged,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onVerifyContact,
    required this.onUpdateContactSettings,
    required this.onBack,
    required this.onOpenAccount,
    required this.onOpenSettings,
    required this.onRetryTor,
    required this.typingContacts,
    required this.onlineContacts,
  });
  final MobileTab tab;
  final String nickname, fingerprint, ownInvite, status, error, notice, action;
  final TransportPhase phase;
  final int? latencyMs;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final String? selectedConversation;
  final ContactRecord? selectedContact;
  final TextEditingController search, composer;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onSearch, onBack;
  final ValueChanged<String?> onSend;
  final ValueChanged<bool> onTypingChanged;
  final ValueChanged<String> onRetryMessage, onDeleteMessage;
  final ValueChanged<String> onVerifyContact;
  final Future<void> Function(ContactRecord, String?, bool, bool)
  onUpdateContactSettings;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;
  final VoidCallback onScanInvite, onShowInvite;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetryTor;
  final Map<String, bool> typingContacts, onlineContacts;

  Widget _content(BuildContext context, {bool desktop = false}) =>
      tab == MobileTab.chats
      ? ChatsView(
          selected: selectedContact,
          contacts: contacts,
          conversations: conversations,
          messages: messages,
          composer: composer,
          onOpenConversation: onOpenConversation,
          onSend: onSend,
          onTypingChanged: onTypingChanged,
          onRetryMessage: onRetryMessage,
          onDeleteMessage: onDeleteMessage,
          onVerifyContact: onVerifyContact,
          onBack: onBack,
          error: error,
          notice: notice,
          showConversationListWhenEmpty: !desktop,
          canSend:
              selectedConversation != null &&
              selectedContact?.verified == true &&
              conversations.any(
                (item) =>
                    item.id == selectedConversation &&
                    item.state == ConversationState.active,
              ),
          peerTyping:
              selectedConversation != null &&
              (typingContacts[selectedConversation] ?? false),
          peerOnline:
              selectedContact != null &&
              (onlineContacts[selectedContact!.id] ?? false),
        )
      : ContactsView(
          saved: contacts,
          search: search,
          onSearch: onSearch,
          onSelect: onStartConversation,
          onScanInvite: onScanInvite,
          onShowInvite: onShowInvite,
          onUpdateContactSettings: onUpdateContactSettings,
          fingerprint: fingerprint,
          ownInvite: ownInvite,
          error: error,
          notice: notice,
          busy: action.isNotEmpty,
          showContactList: !desktop,
        );

  int get unreadTotal => conversations.totalUnread;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 900
        ? DesktopMainShell(
            tab: tab,
            nickname: nickname,
            status: status,
            phase: phase,
            latencyMs: latencyMs,
            contacts: contacts,
            conversations: conversations,
            selectedConversation: selectedConversation,
            unreadTotal: unreadTotal,
            action: action,
            onTab: onTab,
            onOpenConversation: onOpenConversation,
            onStartConversation: onStartConversation,
            onBack: onBack,
            onAccount: onOpenAccount,
            onSettings: onOpenSettings,
            content: _content(context, desktop: true),
          )
        : Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('TorChat'),
                  Text(
                    '@$nickname',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Konto',
                  onPressed: onOpenAccount,
                  icon: const ThemedIcon(Icons.person_outline, size: 18),
                ),
                IconButton(
                  tooltip: 'Tor',
                  onPressed: onRetryTor,
                  icon: const ThemedIcon(Icons.eco_outlined, size: 18),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  TorStatusBar(
                    status: status,
                    phase: phase,
                    latencyMs: latencyMs,
                  ),
                  ActionStatusStrip(action: action),
                  Expanded(
                    child: Padding(
                      padding: selectedConversation == null
                          ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
                          : EdgeInsets.zero,
                      child: _content(context),
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: selectedConversation == null
                ? NavigationBar(
                    selectedIndex: tab.index,
                    onDestinationSelected: (index) =>
                        onTab(MobileTab.values[index]),
                    destinations: [
                      NavigationDestination(
                        icon: CounterBadge(
                          count: unreadTotal,
                          child: const ThemedIcon(Icons.chat_bubble_outline),
                        ),
                        label: 'Czaty',
                      ),
                      NavigationDestination(
                        icon: ThemedIcon(Icons.people_outline),
                        label: 'Kontakty',
                      ),
                    ],
                  )
                : null,
          ),
  );
}

class DesktopMainShell extends StatelessWidget {
  const DesktopMainShell({
    super.key,
    required this.tab,
    required this.nickname,
    required this.status,
    required this.phase,
    required this.latencyMs,
    required this.contacts,
    required this.conversations,
    required this.selectedConversation,
    required this.unreadTotal,
    required this.action,
    required this.onTab,
    required this.onOpenConversation,
    required this.onStartConversation,
    required this.onBack,
    required this.onAccount,
    required this.onSettings,
    required this.content,
  });

  final MobileTab tab;
  final String nickname, status;
  final TransportPhase phase;
  final int? latencyMs;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final String? selectedConversation;
  final String action;
  final int unreadTotal;
  final ValueChanged<MobileTab> onTab;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;
  final VoidCallback onBack;
  final VoidCallback onAccount;
  final VoidCallback onSettings;
  final Widget content;

  ContactRecord? get selectedContact {
    final id = selectedConversation;
    if (id == null) return null;
    final conversation = conversations
        .where((item) => item.id == id)
        .firstOrNull;
    if (conversation == null) return null;
    return contacts
        .where((item) => item.id == conversation.contactId)
        .firstOrNull;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TorStatusBar(
          status: status,
          phase: phase,
          desktop: true,
          latencyMs: latencyMs,
        ),
        ActionStatusStrip(action: action),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 1100;
              final listWidth = compact ? 260.0 : 304.0;
              final showInspector = !compact && selectedContact != null;
              return Row(
                children: [
                  SizedBox(
                    width: compact ? 148 : 176,
                    child: DesktopRail(
                      tab: tab,
                      nickname: nickname,
                      unreadTotal: unreadTotal,
                      onTab: onTab,
                      onAccount: onAccount,
                      onSettings: onSettings,
                    ),
                  ),
                  SizedBox(
                    width: listWidth,
                    child: DesktopListPane(
                      tab: tab,
                      contacts: contacts,
                      conversations: conversations,
                      selectedConversation: selectedConversation,
                      onOpenConversation: onOpenConversation,
                      onStartConversation: onStartConversation,
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: content,
                      ),
                    ),
                  ),
                  if (showInspector)
                    SizedBox(
                      width: 280,
                      child: DesktopInspector(
                        contact: selectedContact!,
                        onBack: onBack,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class DesktopRail extends StatelessWidget {
  const DesktopRail({
    super.key,
    required this.tab,
    required this.nickname,
    required this.unreadTotal,
    required this.onTab,
    required this.onAccount,
    required this.onSettings,
  });
  final MobileTab tab;
  final String nickname;
  final int unreadTotal;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onAccount;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      decoration: BoxDecoration(
        color: shell.surface,
        border: Border(
          right: BorderSide(color: shell.border, width: shell.borderWidth),
        ),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              children: [
                ThemedIcon(Icons.eco_outlined, size: 18),
                SizedBox(width: 8),
                Text('TorChat'),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          for (final item in [
            (MobileTab.chats, Icons.chat_bubble_outline, 'Czaty'),
            (MobileTab.contacts, Icons.people_outline, 'Kontakty'),
          ])
            DesktopNavItem(
              selected: tab == item.$1,
              icon: item.$2,
              label: item.$3,
              alert: item.$1 == MobileTab.chats && unreadTotal > 0,
              badge: item.$1 == MobileTab.chats ? unreadTotal : 0,
              onPressed: () => onTab(item.$1),
            ),
          const Spacer(),
          DesktopNavItem(
            icon: Icons.person_outline,
            label: nickname.isEmpty ? 'Konto' : nickname,
            onPressed: onAccount,
          ),
          DesktopNavItem(
            icon: Icons.settings_outlined,
            label: 'Ustawienia',
            onPressed: onSettings,
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class DesktopNavItem extends StatelessWidget {
  const DesktopNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.alert = false,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final bool alert;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final status = context.statusTheme;
    return SizedBox(
      height: 46,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? shell.selectedNavigationBackground
              : shell.selectedNavigationBackground.withValues(alpha: 0),
          boxShadow: alert
              ? [
                  BoxShadow(
                    color: status.warning.withValues(alpha: .30),
                    blurRadius: 14,
                  ),
                ]
              : null,
          border: selected
              ? Border(
                  left: BorderSide(
                    color: shell.selectedNavigationBorder,
                    width: shell.borderWidth * 3,
                  ),
                )
              : null,
        ),
        child: TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            foregroundColor: selected
                ? shell.selectedNavigationForeground
                : shell.navigationForeground,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
          ),
          icon: ThemedIcon(icon, size: 18),
          label: Row(
            children: [
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
              if (badge > 0) CounterBadge(count: badge),
            ],
          ),
        ),
      ),
    );
  }
}

class DesktopListPane extends StatelessWidget {
  const DesktopListPane({
    super.key,
    required this.tab,
    required this.contacts,
    required this.conversations,
    required this.selectedConversation,
    required this.onOpenConversation,
    required this.onStartConversation,
  });
  final MobileTab tab;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final String? selectedConversation;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: shell.border, width: shell.borderWidth),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: FeatureHeader(
              title: switch (tab) {
                MobileTab.chats => 'Czaty',
                MobileTab.contacts => 'Kontakty',
              },
              subtitle: switch (tab) {
                MobileTab.chats => 'Wybierz rozmowę',
                MobileTab.contacts => 'Wybierz kontakt',
              },
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: tab == MobileTab.chats
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ConversationListSection(
                      title: 'Czaty',
                      subtitle: 'Wybierz rozmowę',
                      conversations: conversations,
                      contacts: contacts,
                      selectedConversation: selectedConversation,
                      onOpenConversation: onOpenConversation,
                      emptyMessage:
                          'Nie masz jeszcze rozmów.\nWybierz osobę w zakładce Kontakty.',
                      asCard: false,
                      showHeader: false,
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: tab == MobileTab.contacts
                        ? [
                            SizedBox(
                              height: 420,
                              child: ContactListSection(
                                title: 'Kontakty',
                                subtitle: 'Wybierz kontakt',
                                contacts: contacts,
                                onSelect: onStartConversation,
                                asCard: false,
                                showHeader: false,
                                emptyMessage: 'Brak kontaktów.',
                              ),
                            ),
                          ]
                        : const [
                            EmptyState(
                              icon: Icons.inbox_outlined,
                              message:
                                  'Otwórz Inbox, aby zarządzać zaproszeniami',
                            ),
                          ],
                  ),
          ),
        ],
      ),
    );
  }
}

class DesktopInspector extends StatelessWidget {
  const DesktopInspector({
    super.key,
    required this.contact,
    required this.onBack,
  });
  final ContactRecord contact;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: shell.surface,
        border: Border(
          left: BorderSide(color: shell.border, width: shell.borderWidth),
        ),
      ),
      child: ListView(
        children: [
          IdentitySection(
            title: 'TOŻSAMOŚĆ',
            name: contact.displayName,
            subtitle: 'Kontakt lokalny',
            fingerprint: contact.fingerprint,
          ),
          const Divider(),
          const SectionCard(
            title: 'POŁĄCZENIE',
            child: InfoTile(title: 'Transport', subtitle: 'Przez onion'),
          ),
          const Divider(),
          const InfoListSection(
            title: 'WSPÓŁDZIELONE',
            items: [
              InfoTile(title: 'Media', subtitle: '0'),
              InfoTile(title: 'Pliki', subtitle: '0'),
              InfoTile(title: 'Linki', subtitle: '0'),
            ],
          ),
          const Divider(),
          TextButton.icon(
            onPressed: onBack,
            icon: const ThemedIcon(Icons.arrow_back),
            label: const Text('Zamknij rozmowę'),
          ),
        ],
      ),
    );
  }
}
