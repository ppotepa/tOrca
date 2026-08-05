import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/application_state/unread_summary.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../core/runtime/message_paging.dart';
import '../../shared/widgets/counter_badge.dart';
import '../chats/release_chat_view.dart';
import '../chats/composer_draft.dart';
import '../contacts/contacts_view.dart';
import '../../platform/desktop/desktop_workspace.dart';
import '../../shared/widgets/tor_status_bar.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/domain/user_problem.dart';
import '../../locales/presentation/problem_localizer.dart';

class MainShell extends ConsumerWidget {
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
    this.readiness,
    this.transportStatuses = const {},
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.selectedConversation,
    required this.selectedContact,
    required this.search,
    required this.composer,
    required this.error,
    this.problem,
    required this.action,
    required this.onTab,
    required this.onSearch,
    required this.onOpenConversation,
    required this.onStartConversation,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.onSend,
    required this.onTypingChanged,
    this.onConversationFocusChanged = _ignoreConversationFocus,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onLoadOlderMessages,
    required this.onVerifyContact,
    required this.onUpdateContactSettings,
    required this.onBack,
    required this.onOpenAccount,
    required this.onOpenSettings,
    required this.onRetryTor,
    required this.typingContacts,
    this.pendingPairings = const [],
    this.lastSeenEnabled = true,
    this.onOpenConnectionCenter,
  });

  final MobileTab tab;
  final String nickname;
  final String fingerprint;
  final String ownInvite;
  final String status;
  final String error;
  final UserProblem? problem;
  final String action;
  final TransportPhase phase;
  final PeerServerStatus peerServerStatus;
  final ConnectionReadiness? readiness;
  final Map<TransportComponent, TransportStatusSnapshot> transportStatuses;
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
  final Future<void> Function(ComposerDraft draft) onSend;
  final ValueChanged<bool> onTypingChanged;
  final void Function(String conversationId, bool focused)
  onConversationFocusChanged;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final Future<OlderMessagesResult> Function(String conversationId)
  onLoadOlderMessages;
  final ValueChanged<String> onVerifyContact;
  final Future<void> Function(
    ContactRecord,
    String?,
    bool,
    bool,
    ContactTransportPolicy,
  )
  onUpdateContactSettings;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<ContactRecord> onStartConversation;
  final VoidCallback onScanInvite;
  final VoidCallback onShowInvite;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetryTor;
  final VoidCallback? onOpenConnectionCenter;
  final Map<String, bool> typingContacts;
  final List<PairingItem> pendingPairings;
  final bool lastSeenEnabled;

  VoidCallback get _openConnectionCenter =>
      onOpenConnectionCenter ?? onRetryTor;

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
        onTab(MobileTab.chats),
    const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
        onTab(MobileTab.contacts),
    const SingleActivator(LogicalKeyboardKey.comma, control: true):
        onOpenSettings,
    const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
        onOpenAccount,
    const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true):
        onRetryTor,
    const SingleActivator(LogicalKeyboardKey.escape): () {
      if (selectedConversation != null) onBack();
    },
  };

  Widget _content(
    BuildContext context,
    WidgetRef ref, {
    required bool desktop,
  }) {
    final presence = ref.watch(contactPresenceStoreProvider);
    final selectedPresence = selectedContact == null
        ? const ContactPresenceSnapshot(contactId: '')
        : presence.snapshot(selectedContact!.id);
    final localizedError = problem == null
        ? error
        : localizeProblem(context.l10n, problem!);
    return tab == MobileTab.chats
        ? ReleaseChatView(
            selected: selectedContact,
            contacts: contacts,
            conversations: conversations,
            messages: messages,
            composer: composer,
            onOpenConversation: onOpenConversation,
            onSend: onSend,
            onTypingChanged: onTypingChanged,
            onConversationFocusChanged: onConversationFocusChanged,
            onRetryMessage: onRetryMessage,
            onDeleteMessage: onDeleteMessage,
            onLoadOlderMessages: () =>
                onLoadOlderMessages(selectedConversation ?? ''),
            onBack: onBack,
            error: localizedError,
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
            availability: selectedPresence.availability,
            peerFocused: selectedPresence.isViewingConversation,
            lastSeenAt: selectedContact == null || !lastSeenEnabled
                ? null
                : selectedPresence.lastSeenAt ??
                      int.tryParse(selectedContact!.lastSeenAt ?? ''),
            headerStatus: desktop
                ? null
                : ConnectionStatusLamp(
                    embeddedInHeader: true,
                    phase: phase,
                    peerStatus: peerServerStatus,
                    readiness: readiness,
                    onOpenConnectionCenter: _openConnectionCenter,
                  ),
          )
        : ContactsView(
            saved: contacts,
            conversations: conversations,
            pendingPairings: pendingPairings,
            search: search,
            onSearch: onSearch,
            onSelect: onStartConversation,
            onScanInvite: onScanInvite,
            onShowInvite: onShowInvite,
            canPair: readiness?.canPerform(ConnectionOperation.pair) ?? false,
            onUpdateContactSettings: onUpdateContactSettings,
            fingerprint: fingerprint,
            ownInvite: ownInvite,
            error: localizedError,
            showContactList: !desktop,
          );
  }

  int get unreadContactCount => conversations.unreadSummary.contactsWithUnread;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: _shortcuts,
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          if (desktop) {
            return Scaffold(
              body: Semantics(
                label: context.l10n.uiMainWorkspaceSemantics,
                container: true,
                child: Column(
                  children: [
                    ConnectionStatusLamp(
                      phase: phase,
                      peerStatus: peerServerStatus,
                      readiness: readiness,
                      onOpenConnectionCenter: _openConnectionCenter,
                    ),
                    Expanded(
                      child: DesktopWorkspace(
                        tab: tab,
                        nickname: nickname,
                        contacts: contacts,
                        conversations: conversations,
                        selectedConversation: selectedConversation,
                        selectedContact: selectedContact,
                        presenceStore: ref.watch(contactPresenceStoreProvider),
                        content: _content(context, ref, desktop: true),
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
              ),
            );
          }

          return Scaffold(
            appBar: selectedConversation == null
                ? AppBar(
                    title: Row(
                      children: [
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(context.l10n.appTitle),
                              Text(
                                '@$nickname',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConnectionStatusLamp(
                          embeddedInHeader: true,
                          phase: phase,
                          peerStatus: peerServerStatus,
                          readiness: readiness,
                          onOpenConnectionCenter: _openConnectionCenter,
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: context.l10n.shellAccount,
                        onPressed: onOpenAccount,
                        icon: const ThemedIcon(Icons.person_outline, size: 18),
                      ),
                      IconButton(
                        tooltip: context.l10n.shellSettings,
                        onPressed: onOpenSettings,
                        icon: const ThemedIcon(
                          Icons.settings_outlined,
                          size: 18,
                        ),
                      ),
                    ],
                  )
                : null,
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: selectedConversation == null
                          ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
                          : EdgeInsets.zero,
                      child: _content(context, ref, desktop: false),
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
                          count: unreadContactCount,
                          semanticLabel: context.l10n
                              .uiUnreadContactsSemantics(unreadContactCount),
                          child: const ThemedIcon(Icons.chat_bubble_outline),
                        ),
                        label: context.l10n.uiChats,
                      ),
                      NavigationDestination(
                        icon: const ThemedIcon(Icons.people_outline),
                        label: context.l10n.uiContacts,
                      ),
                    ],
                  )
                : null,
          );
        },
      ),
    ),
  );
}

void _ignoreConversationFocus(String conversationId, bool focused) {}
