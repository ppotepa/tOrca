import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'app/app_controller.dart';
import 'app/app_theme.dart';
import 'app/application_snapshot_provider.dart';
import 'app/conversation_navigation_intent.dart';
import 'app/desktop_navigation_intent.dart';
import 'app/desktop_notification_service.dart';
import 'app/desktop_window_lifecycle.dart';
import 'app/notifications/ui_notification_center.dart';
import 'client_runtime.dart';
import 'core/connection/app_state_connection.dart';
import 'core/connection/connection_gate.dart';
import 'features/account/account_view.dart';
import 'features/account/settings_view.dart';
import 'features/connection/connection_center_sheet.dart';
import 'features/invites/invite_scanner.dart';
import 'features/onboarding/connection_warmup_screen.dart';
import 'features/onboarding/nickname_onboarding_screen.dart';
import 'features/onboarding/onboarding_views.dart';
import 'features/shell/main_shell.dart';
import 'features/chats/composer_draft.dart';
import 'shared/widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!await DesktopWindowLifecycle.initialize()) return;
  runApp(const TorChatMobileApp());
}

class TorChatMobileApp extends StatelessWidget {
  const TorChatMobileApp({super.key, this.runtime});

  final ClientRuntime? runtime;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: runtime == null
          ? const []
          : [clientRuntimeProvider.overrideWithValue(runtime!)],
      child: const _TorChatAppView(),
    );
  }
}

class _TorChatAppView extends ConsumerWidget {
  const _TorChatAppView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeControllerProvider);
    final preferences =
        themeState.valueOrNull ?? const TorChatThemePreferences();

    return MaterialApp(
      title: 'TorChat',
      debugShowCheckedModeBanner: false,
      theme: TorChatThemeRegistry.light(
        preferences.family,
        retroPalette: preferences.retroPalette,
      ),
      darkTheme: TorChatThemeRegistry.dark(
        preferences.family,
        retroPalette: preferences.retroPalette,
      ),
      themeMode: switch (preferences.brightness) {
        TorChatBrightnessMode.system => ThemeMode.system,
        TorChatBrightnessMode.light => ThemeMode.light,
        TorChatBrightnessMode.dark => ThemeMode.dark,
      },
      builder: (context, child) =>
          ToastHost(child: child ?? const SizedBox.shrink()),
      home: const ControllerHomePage(),
    );
  }
}

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
  bool _onboardingUnlocked = false;
  bool _runningUnlocked = false;
  bool _incomingPairingDialogOpen = false;
  bool _pairingCodeDialogOpen = false;
  // A prompt can be requested while the page is changing route (notably just
  // after a pairing code was submitted).  Keep only a *scheduled* marker;
  // marking it permanently as presented before showDialog has mounted loses
  // the only accept/reject affordance when that frame cannot present a route.
  final Set<String> _scheduledIncomingPairingIds = <String>{};
  final Set<String> _resolvedIncomingPairingIds = <String>{};
  String _reattachedNickname = '';
  Timer? _backgroundDebounce;
  StreamSubscription<DesktopNavigationIntent>? _desktopNavigationSubscription;
  StreamSubscription<ConversationNavigationIntent>?
  _conversationNavigationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktopPlatform) {
      _desktopNavigationSubscription = DesktopNavigationIntents.stream.listen((
        intent,
      ) {
        if (!mounted) return;
        switch (intent) {
          case DesktopNavigationIntent.openSettings:
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
    if (runtime is RuntimeAttachmentProvider) {
      snapshot = await (runtime as RuntimeAttachmentProvider).runtimeSnapshot();
    }
    final profile = snapshot?['profile'];
    if (profile is Map) {
      final nickname = profile['nickname']?.toString().trim() ?? '';
      if (nickname.length >= 2 && mounted) {
        setState(() {
          _reattachedNickname = nickname;
        });
      }
    }
    if (mounted) {
      await ref.read(appControllerProvider.notifier).initialize();
    }
  }

  Future<void> _openConversationFromNotification(
    ConversationNavigationIntent intent,
  ) async {
    if (isDesktopPlatform) {
      await DesktopWindowLifecycle.instance.showWindow();
    }
    final controller = ref.read(appControllerProvider.notifier);
    for (var attempt = 0; attempt < 12 && mounted; attempt += 1) {
      final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
      final conversations =
          snapshot?.conversations ?? const <ConversationSummary>[];
      if (conversations.any((item) => item.id == intent.conversationId)) {
        await controller.openConversation(intent.conversationId);
        await DesktopNotificationService.clear(intent.notificationId);
        return;
      }
      await controller.refreshData(forcePairing: false, allowAutoTorka: false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _queueIncomingPairingPrompt(List<PairingItem> inbox) {
    if (!mounted ||
        !_runningUnlocked ||
        _pairingCodeDialogOpen ||
        _incomingPairingDialogOpen) {
      return;
    }
    final request = inbox.firstOrNullWhere(
      (item) =>
          item.received &&
          item.origin == PairingOrigin.inbox &&
          item.can(PairingAvailableAction.accept) &&
          !_resolvedIncomingPairingIds.contains(item.id) &&
          !_scheduledIncomingPairingIds.contains(item.id),
    );
    if (request == null) return;

    _scheduledIncomingPairingIds.add(request.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pairingCodeDialogOpen || _incomingPairingDialogOpen) {
        _scheduledIncomingPairingIds.remove(request.id);
        return;
      }
      unawaited(_showIncomingPairingPrompt(request));
    });
  }

  Future<void> _showIncomingPairingPrompt(PairingItem request) async {
    if (!mounted || _pairingCodeDialogOpen || _incomingPairingDialogOpen) {
      _scheduledIncomingPairingIds.remove(request.id);
      return;
    }
    _incomingPairingDialogOpen = true;
    final controller = ref.read(appControllerProvider.notifier);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => IncomingPairingDialog(
          request: request,
          onAccept: () async {
            await controller.acceptPairing(request.id);
            _resolvedIncomingPairingIds.add(request.id);
            await controller.refreshData(
              forcePairing: true,
              allowAutoTorka: false,
            );
          },
          onReject: () async {
            await controller.rejectPairing(request.id);
            _resolvedIncomingPairingIds.add(request.id);
            await controller.refreshData(
              forcePairing: true,
              allowAutoTorka: false,
            );
          },
        ),
      );
    } finally {
      _incomingPairingDialogOpen = false;
      // The dialog itself is the presentation lock.  Releasing this marker
      // means a failed route presentation is retried from the persisted inbox
      // instead of silently hiding a still-pending invitation forever.
      _scheduledIncomingPairingIds.remove(request.id);
      if (mounted) {
        _queueIncomingPairingPrompt(ref.read(appControllerProvider).inbox);
      }
    }
  }

  void _showPairingOutcomeToast(
    List<PairingItem>? previous,
    List<PairingItem> current,
  ) {
    if (!mounted || previous == null) return;
    final previousById = {for (final item in previous) item.id: item};
    for (final item in current) {
      if (item.origin != PairingOrigin.outbox || item.received) continue;
      final old = previousById[item.id];
      if (old == null || old.status != InviteState.pending) continue;

      final message = switch (item.status) {
        InviteState.accepted || InviteState.completed =>
          '${item.peer?.displayName ?? 'Użytkownik'} przyjął Twoje zaproszenie.',
        InviteState.rejected =>
          '${item.peer?.displayName ?? 'Użytkownik'} odrzucił Twoje zaproszenie.',
        InviteState.expired => 'Zaproszenie wygasło bez odpowiedzi.',
        InviteState.cancelled => 'Zaproszenie zostało anulowane.',
        _ => null,
      };
      if (message == null) continue;
      final key = 'pairing:${item.id}:${item.status.name}';
      final notifications = ref.read(uiNotificationCenterProvider.notifier);
      switch (item.status) {
        case InviteState.accepted || InviteState.completed:
          notifications.showSuccess(message, deduplicationKey: key);
        case InviteState.rejected || InviteState.expired:
          notifications.showWarning(message, deduplicationKey: key);
        case InviteState.cancelled:
          notifications.showInfo(message, deduplicationKey: key);
        default:
          break;
      }
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
          if (!mounted) return;
          unawaited(
            ref.read(appControllerProvider.notifier).updateVisibility(false),
          );
        });
    }
  }

  Future<void> _showInvite() async {
    if (_pairingCodeDialogOpen || _incomingPairingDialogOpen) return;
    _pairingCodeDialogOpen = true;
    final controller = ref.read(appControllerProvider.notifier);
    final code = await controller.refreshInviteCode();
    if (!mounted) {
      _pairingCodeDialogOpen = false;
      return;
    }
    if (code == null) {
      final error = ref.read(appControllerProvider).error;
      try {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Nie można wygenerować kodu'),
            content: Text(
              error.isEmpty ? 'Połączenie z relayem nie jest gotowe.' : error,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Zamknij'),
              ),
            ],
          ),
        );
      } finally {
        _pairingCodeDialogOpen = false;
        if (mounted) {
          _queueIncomingPairingPrompt(ref.read(appControllerProvider).inbox);
        }
      }
      return;
    }
    final knownInboxIds = ref
        .read(appControllerProvider)
        .inbox
        .map((item) => item.id)
        .toSet();
    try {
      await showDialog<bool>(
        context: context,
        builder: (_) => PairingCodeDialog(
          initialCode: code.code,
          initialExpiresAt: code.expiresAt,
          refresh: controller.refreshInviteCode,
          onChanged: (_) {},
          checkRequest: () async {
            await controller.refreshData(forcePairing: true);
            final inbox = ref.read(appControllerProvider).inbox;
            return inbox.firstOrNullWhere(
              (item) =>
                  !knownInboxIds.contains(item.id) &&
                  !_resolvedIncomingPairingIds.contains(item.id) &&
                  item.can(PairingAvailableAction.accept),
            );
          },
          onAccept: (request) async {
            await controller.acceptPairing(request.id);
            _resolvedIncomingPairingIds.add(request.id);
            final peerId = request.peer?.id;
            if (peerId == null || peerId.isEmpty) return false;
            for (var attempt = 0; attempt < 15; attempt += 1) {
              await controller.refreshData(forcePairing: true);
              final contacts =
                  ref.read(applicationSnapshotProvider).valueOrNull?.contacts ??
                  ref.read(appControllerProvider).contacts;
              if (contacts.any((contact) => contact.id == peerId)) return true;
              await Future<void>.delayed(const Duration(seconds: 1));
            }
            return false;
          },
          onReject: (request) async {
            await controller.rejectPairing(request.id);
            _resolvedIncomingPairingIds.add(request.id);
          },
        ),
      );
    } finally {
      _pairingCodeDialogOpen = false;
      if (mounted) {
        _queueIncomingPairingPrompt(ref.read(appControllerProvider).inbox);
      }
    }
  }

  Future<void> _showTransportStatus() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const ConnectionCenterSheet(),
  );

  Future<void> _scanInvite() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const InviteScannerPage()),
    );
    if (!mounted || value == null) return;
    await ref.read(appControllerProvider.notifier).submitPairingCode(value);
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

  void _openAccount() {
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    final profile = snapshot?.profile ?? const RuntimeProfile();
    final identity = snapshot?.identity ?? const RuntimeIdentity();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountView(
          nickname: profile.nickname,
          installationId: identity.installationId,
          fingerprint: profile.fingerprint,
          onShowInvite: () {
            Navigator.pop(context);
            _showInvite();
          },
          onOpenSettings: () {
            Navigator.pop(context);
            _openSettings();
          },
        ),
      ),
    );
  }

  void _openSettings() {
    final state = ref.read(appControllerProvider);
    final summary = state.connectionSummary;
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsView(
          nickname: snapshot?.profile.nickname ?? state.profile.nickname,
          torStatus: summary.status,
          themePreferences:
              ref.read(themeControllerProvider).valueOrNull ??
              const TorChatThemePreferences(),
          onThemeFamilyChanged: (family) {
            unawaited(
              ref.read(themeControllerProvider.notifier).setFamily(family),
            );
          },
          onBrightnessChanged: (brightness) {
            unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .setBrightness(brightness),
            );
          },
          onRetroPaletteChanged: (palette) {
            unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .setRetroPalette(palette),
            );
          },
          onOpenTor: () {
            Navigator.pop(context);
            _showTransportStatus();
          },
          onEditProfile: () {
            Navigator.pop(context);
            _editNickname();
          },
          onReset: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Reset danych demo'),
              content: const Text(
                'Reset lokalnego stanu wykonaj przez deploy z opcją resetu.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Zamknij'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Handles the Android system back gesture before the root route is popped.
  ///
  /// The app keeps the active conversation and the selected top-level tab in
  /// controller state rather than in Navigator routes. Without this bridge,
  /// Android sees a single root route and immediately backgrounds the whole
  /// application, even when the user is visibly inside a conversation.
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

    // At the root of the app the native Android behaviour is intentional:
    // leave the Flutter activity and keep the foreground service alive.
    await SystemNavigator.pop();
  }

  Future<void> _editNickname() async {
    final appController = ref.read(appControllerProvider.notifier);
    final state = ref.read(appControllerProvider);
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    final field = TextEditingController(
      text: snapshot?.profile.nickname ?? state.profile.nickname,
    );
    final nickname = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edytuj nick'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 32,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Nick'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    field.dispose();
    if (nickname != null && nickname.trim().isNotEmpty) {
      await appController.setNickname(nickname);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    ref.listen<List<PairingItem>>(
      appControllerProvider.select((value) => value.inbox),
      (_, inbox) => _queueIncomingPairingPrompt(inbox),
    );
    ref.listen<List<PairingItem>>(
      appControllerProvider.select((value) => value.outbox),
      _showPairingOutcomeToast,
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

    if (resolvedPhase == AppLaunchPhase.onboarding) {
      _onboardingUnlocked = true;
    }
    if (resolvedPhase == AppLaunchPhase.running) {
      _runningUnlocked = true;
    }

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
        error: state.error,
        retry: controller.retryTor,
      );
    }
    if (launchPhase == AppLaunchPhase.onboarding) {
      return NicknameOnboardingScreen(
        controller: _nickname,
        connection: connection,
        error: state.error,
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

    final contacts = snapshot?.contacts ?? const <ContactRecord>[];
    final conversations =
        snapshot?.conversations ?? const <ConversationSummary>[];
    final pendingPairings = <String, PairingItem>{};
    for (final item in [...state.inbox, ...state.outbox]) {
      if (item.status == InviteState.pending ||
          item.status == InviteState.accepted) {
        pendingPairings[item.id] = item;
      }
    }
    final selectedContact = state.selectedContact(contacts, conversations);
    final shell = MainShell(
      tab: switch (state.destination) {
        MainDestination.contacts => MobileTab.contacts,
        _ => MobileTab.chats,
      },
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
      contacts: contacts,
      pendingPairings: pendingPairings.values.toList(growable: false),
      conversations: conversations,
      messages: messageSnapshot?.messages ?? const <ChatMessage>[],
      selectedConversation: state.selectedConversationId,
      selectedContact: selectedContact,
      search: _search,
      composer: _composer,
      error: state.error,
      action: state.action,
      onTab: (tab) => controller.selectDestination(switch (tab) {
        MobileTab.contacts => MainDestination.contacts,
        MobileTab.chats => MainDestination.chats,
      }),
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
      onlineContacts: const {},
      idleContacts: const {},
      focusedConversations: const {},
      lastSeenContacts: const {},
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
