part of 'torca_app.dart';

class ControllerHomePage extends ConsumerStatefulWidget {
  const ControllerHomePage({super.key});

  @override
  ConsumerState<ControllerHomePage> createState() => _ControllerHomePageState();
}

class _ControllerHomePageState extends ConsumerState<ControllerHomePage>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _composer = TextEditingController();
  final _nickname = TextEditingController();
  final PairingUiCoordinator _pairingUi = PairingUiCoordinator();
  bool _onboardingUnlocked = false;
  bool _runningUnlocked = false;
  String _reattachedNickname = '';
  Timer? _backgroundDebounce;
  StreamSubscription<DesktopNavigationIntent>? _desktopNavigationSubscription;
  StreamSubscription<ConversationNavigationIntent>?
  _conversationNavigationSubscription;

  AppLocalizations get _l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktopPlatform) {
      _desktopNavigationSubscription = PlatformServices
          .current
          .navigation
          .stream
          .listen((intent) {
            if (!mounted) return;
            if (intent == DesktopNavigationIntent.openSettings) {
              _openSettings();
            }
          });
    }
    _conversationNavigationSubscription = ConversationNavigationIntents.stream
        .listen((intent) {
          if (mounted) unawaited(_openConversationFromNotification(intent));
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_attachAndInitialize());
    });
  }

  Future<void> _attachAndInitialize() async {
    final runtime = ref.read(clientRuntimeProvider);
    Map<String, dynamic>? snapshot;
    snapshot = await runtime.runtimeSnapshot();
    final profile = snapshot?['profile'];
    if (profile is Map) {
      final nickname = profile['nickname']?.toString().trim() ?? '';
      if (nickname.length >= 2 && mounted) {
        setState(() => _reattachedNickname = nickname);
      }
    }
    if (mounted) await ref.read(appControllerProvider.notifier).initialize();
  }

  Future<void> _openConversationFromNotification(
    ConversationNavigationIntent intent,
  ) async {
    if (isDesktopPlatform) {
      await PlatformServices.current.windowLifecycle.showWindow();
    }
    final controller = ref.read(appControllerProvider.notifier);
    await controller.refreshData();
    if (!mounted) return;
    final conversations =
        ref.read(applicationSnapshotProvider).valueOrNull?.conversations ??
        ref.read(appControllerProvider).conversations;
    if (!conversations.any((item) => item.id == intent.conversationId)) return;
    await controller.openConversation(intent.conversationId);
    await PlatformServices.current.notifications.clear(intent.notificationId);
  }

  void _queueIncomingPairingPrompt(List<PairingItem> inbox) {
    if (!mounted || !_runningUnlocked || _pairingUi.codeSurfaceOpen) return;
    final request = inbox.firstOrNullWhere(
      (item) => item.requiresLocalDecision && _pairingUi.canSchedule(item),
    );
    if (request == null) return;
    _pairingUi.schedule(request.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pairingUi.codeSurfaceOpen) {
        _pairingUi.unschedule(request.id);
        return;
      }
      unawaited(_showIncomingPairingPrompt(request));
    });
  }

  void _showPairingOutcomeToast(
    List<PairingItem>? previous,
    List<PairingItem> current,
  ) {
    if (!mounted || previous == null) return;
    final previousById = {for (final item in previous) item.id: item};
    for (final item in current) {
      final old = previousById[item.id];
      if (old == null || old.status == item.status) continue;
      final peerName = item.peer?.displayName.trim();
      final name = peerName == null || peerName.isEmpty
          ? _l10n.uiUnknownUser
          : peerName;
      final message = switch (item.status) {
        InviteState.accepted ||
        InviteState.completed => _l10n.uiPairingAccepted(name),
        InviteState.rejected => _l10n.uiPairingRejected(name),
        InviteState.expired => _l10n.uiPairingExpired,
        InviteState.cancelled => _l10n.uiPairingCancelled,
        _ => null,
      };
      if (message == null) continue;
      final key = 'pairing:${item.id}:${item.status.name}';
      final notifications = ref.read(uiNotificationCenterProvider.notifier);
      switch (item.status) {
        case InviteState.completed:
          notifications.showSuccess(message, deduplicationKey: key);
        case InviteState.accepted:
          notifications.showInfo(message, deduplicationKey: key);
        case InviteState.rejected || InviteState.expired:
          notifications.showWarning(message, deduplicationKey: key);
        case InviteState.cancelled:
          notifications.showInfo(message, deduplicationKey: key);
        default:
          break;
      }
    }
  }

  void _showNewContactToast(
    List<ContactRecord>? previous,
    List<ContactRecord> current,
  ) {
    if (!mounted || previous == null) return;
    final previousIds = previous.map((contact) => contact.id).toSet();
    for (final contact in current) {
      if (previousIds.contains(contact.id)) continue;
      final name = contact.displayName.trim().isEmpty
          ? _l10n.newContact
          : contact.displayName;
      ref
          .read(uiNotificationCenterProvider.notifier)
          .showSuccess(
            _l10n.uiContactAdded(name),
            deduplicationKey: 'contact-added:${contact.id}',
          );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _desktopNavigationSubscription?.cancel();
    _conversationNavigationSubscription?.cancel();
    _backgroundDebounce?.cancel();
    _search.dispose();
    _composer.dispose();
    _nickname.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        ref.read(appControllerProvider.notifier).reattachPresence();
        _backgroundDebounce?.cancel();
        _backgroundDebounce = null;
        unawaited(
          ref.read(appControllerProvider.notifier).updateVisibility(true),
        );
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _backgroundDebounce?.cancel();
        _backgroundDebounce = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            unawaited(
              ref.read(appControllerProvider.notifier).updateVisibility(false),
            );
          }
        });
    }
  }

  Future<void> _sendMessage(ComposerDraft draft) async {
    if (draft.isEmpty) return;
    final controller = ref.read(appControllerProvider.notifier);
    if (draft.caption.trim().isNotEmpty) {
      await controller.sendMessage(
        draft.caption.trim(),
        replyToMessageId: draft.replyToMessageId,
      );
    }
    for (final attachment in draft.attachments) {
      await controller.sendMessage(attachment.attachment.toMessageBody());
    }
  }

  Future<void> _handleSystemBack() async {
    if (!mounted) return;
    final controller = ref.read(appControllerProvider.notifier);
    final state = ref.read(appControllerProvider);
    if (state.selectedConversationId != null) {
      controller.closeConversation();
      return;
    }
    if (state.destination != MainDestination.chats) {
      controller.selectDestination(MainDestination.chats);
      return;
    }
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final localizedError =
        localizeStateProblem(
          _l10n,
          problem: state.problem,
          diagnosticError: state.error,
        ) ??
        '';
    ref.listen<List<PairingItem>>(
      appControllerProvider.select((value) => value.inbox),
      (previous, inbox) {
        _queueIncomingPairingPrompt(inbox);
        _showPairingOutcomeToast(previous, inbox);
      },
    );
    ref.listen<List<PairingItem>>(
      appControllerProvider.select((value) => value.outbox),
      _showPairingOutcomeToast,
    );
    ref.listen<List<ContactRecord>>(
      appControllerProvider.select((value) => value.contacts),
      _showNewContactToast,
    );
    final snapshot = ref.watch(applicationSnapshotProvider).valueOrNull;
    final messageSnapshot = ref
        .watch(conversationMessagesProvider(state.selectedConversationId ?? ''))
        .valueOrNull;
    final controller = ref.read(appControllerProvider.notifier);
    final connection = state.connectionReadiness;
    final summary = state.connectionSummary;
    final profile = snapshot?.profile ?? state.profile;
    final identity = snapshot?.identity ?? state.identity;
    final effectiveNickname = profile.nickname.trim().isNotEmpty
        ? profile.nickname
        : _reattachedNickname;
    final resolvedPhase = resolveLaunchPhase(
      profile: profile,
      connection: connection,
    );
    if (resolvedPhase == AppLaunchPhase.onboarding) _onboardingUnlocked = true;
    if (resolvedPhase == AppLaunchPhase.running) _runningUnlocked = true;
    final launchPhase = _runningUnlocked
        ? AppLaunchPhase.running
        : _onboardingUnlocked && profile.nickname.trim().isEmpty
        ? AppLaunchPhase.onboarding
        : resolvedPhase;
    if (launchPhase == AppLaunchPhase.running) {
      _queueIncomingPairingPrompt(state.inbox);
    }
    if (launchPhase == AppLaunchPhase.warming) {
      return ConnectionWarmupScreen(
        connection: connection,
        summary: summary,
        error: localizedError,
        retry: controller.retryTor,
      );
    }
    if (launchPhase == AppLaunchPhase.onboarding) {
      return NicknameOnboardingScreen(
        controller: _nickname,
        connection: connection,
        error: localizedError,
        onSave: () async {
          await controller.setNickname(_nickname.text);
          if (ref
              .read(appControllerProvider)
              .profile
              .nickname
              .trim()
              .isNotEmpty) {
            _nickname.clear();
          }
        },
      );
    }
    final pendingPairings = <String, PairingItem>{};
    for (final item in [...state.inbox, ...state.outbox]) {
      if (item.status == InviteState.pending ||
          item.status == InviteState.accepted) {
        pendingPairings[item.id] = item;
      }
    }
    final selectedContact = state.selectedContact(
      state.contacts,
      state.conversations,
    );
    final shell = MainShell(
      tab: state.destination == MainDestination.contacts
          ? MobileTab.contacts
          : MobileTab.chats,
      nickname: effectiveNickname,
      fingerprint: profile.fingerprint.isNotEmpty
          ? profile.fingerprint
          : identity.fingerprint,
      ownInvite: state.ownInvite?.code ?? '',
      status: summary.status,
      phase: summary.phase,
      latencyMs: summary.latencyMs,
      peerServerStatus: summary.peerServerStatus,
      readiness: connection,
      transportStatuses: state.transportStatuses,
      contacts: state.contacts,
      pendingPairings: pendingPairings.values.toList(growable: false),
      conversations: state.conversations,
      messages: messageSnapshot?.messages ?? const <ChatMessage>[],
      selectedConversation: state.selectedConversationId,
      selectedContact: selectedContact,
      search: _search,
      composer: _composer,
      error: localizedError,
      problem: state.problem,
      action: state.action,
      onTab: (tab) => controller.selectDestination(
        tab == MobileTab.contacts
            ? MainDestination.contacts
            : MainDestination.chats,
      ),
      onSearch: () => controller.submitPairingCode(_search.text),
      onOpenConversation: controller.openConversation,
      onStartConversation: controller.openOrStartConversation,
      onScanInvite: _scanInvite,
      onShowInvite: _showInvite,
      onSend: _sendMessage,
      onTypingChanged: controller.setTyping,
      onConversationFocusChanged: controller.setConversationFocus,
      onRetryMessage: controller.retryMessage,
      onDeleteMessage: controller.deleteMessageLocal,
      onLoadOlderMessages: controller.loadOlderMessages,
      onVerifyContact: controller.verifyContact,
      onUpdateContactSettings: controller.updateContactSettings,
      onBack: controller.closeConversation,
      onOpenAccount: _openAccount,
      onOpenSettings: _openSettings,
      onRetryTor: _showTransportStatus,
      typingContacts: state.typingContacts,
      lastSeenEnabled: state.lastSeenEnabled,
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      return PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_handleSystemBack());
        },
        child: shell,
      );
    }
    return shell;
  }
}
