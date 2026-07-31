import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/widgets/counter_badge.dart';
import '../chats/chats_view.dart';
import '../contacts/contacts_view.dart';
import 'desktop/cockpit_status_bar.dart';
import 'desktop/desktop_workspace.dart';

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
    required this.peerServerStatus,
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
    this.onOpenConnectionCenter,
  });

  final MobileTab tab;
  final String nickname;
  final String fingerprint;
  final String ownInvite;
  final String status;
  final String error;
  final String notice;
  final String action;
  final TransportPhase phase;
  final PeerServerStatus peerServerStatus;
  final int? latencyMs;
  final List<ContactRecord> contacts;
  final List<ConversationSummary> conversations;
  final List<ChatMessage> messages;
  final String? selectedConversation;
  final ContactRecord? selectedContact;
  final TextEditingController search;
  final TextEditingController composer;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onSearch;
  final VoidCallback onBack;
  final ValueChanged<String?> onSend;
  final ValueChanged<bool> onTypingChanged;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final ValueChanged<String> onVerifyContact;
  final Future<void> Function(
    ContactRecord,
    String?,
    bool,
    bool,
    ContactTransportPolicy,
  ) onUpdateContactSettings;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;
  final VoidCallback onScanInvite;
  final VoidCallback onShowInvite;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetryTor;
  final VoidCallback? onOpenConnectionCenter;
  final Map<String, bool> typingContacts;
  final Map<String, bool> onlineContacts;

  VoidCallback get _openConnectionCenter =>
      onOpenConnectionCenter ?? onRetryTor;

  Widget _content(BuildContext context, {required bool desktop}) =>
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
              canSend: selectedConversation != null &&
                  selectedContact?.verified == true &&
                  conversations.any(
                    (item) => item.id == selectedConversation &&
                        item.state == ConversationState.active,
                  ),
              peerTyping: selectedConversation != null &&
                  (typingContacts[selectedConversation] ?? false),
              peerOnline: selectedContact != null &&
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
              busy: false,
              showContactList: !desktop,
            );

  int get unreadTotal => conversations.totalUnread;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          if (desktop) {
            return Scaffold(
              body: Column(
                children: [
                  CockpitStatusBar(
                    phase: phase,
                    peerServerStatus: peerServerStatus,
                    nickname: nickname,
                    latencyMs: latencyMs,
                    onOpenConnectionCenter: _openConnectionCenter,
                    onOpenSettings: onOpenSettings,
                  ),
                  Expanded(
                    child: DesktopWorkspace(
                      tab: tab,
                      nickname: nickname,
                      contacts: contacts,
                      conversations: conversations,
                      selectedConversation: selectedConversation,
                      selectedContact: selectedContact,
                      onlineContacts: onlineContacts,
                      content: _content(context, desktop: true),
                      onTab: onTab,
                      onOpenConversation: onOpenConversation,
                      onStartConversation: onStartConversation,
                      onVerifyContact: onVerifyContact,
                      onBack: onBack,
                      onAccount: onOpenAccount,
                      onSettings: onOpenSettings,
                    ),
                  ),
                ],
              ),
            );
          }

          return Scaffold(
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
                  tooltip: 'Ustawienia',
                  onPressed: onOpenSettings,
                  icon: const ThemedIcon(Icons.settings_outlined, size: 18),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  CompactCockpitStatusBar(
                    phase: phase,
                    peerServerStatus: peerServerStatus,
                    latencyMs: latencyMs,
                    onOpenConnectionCenter: _openConnectionCenter,
                  ),
                  Expanded(
                    child: Padding(
                      padding: selectedConversation == null
                          ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
                          : EdgeInsets.zero,
                      child: _content(context, desktop: false),
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
                      const NavigationDestination(
                        icon: ThemedIcon(Icons.people_outline),
                        label: 'Kontakty',
                      ),
                    ],
                  )
                : null,
          );
        },
      );
}
