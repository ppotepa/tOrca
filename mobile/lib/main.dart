import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_controller.dart';
import 'app/app_theme.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  String _reattachedNickname = '';
  Timer? _backgroundDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_attachAndInitialize());
    });
  }

  Future<void> _attachAndInitialize() async {
    final runtime = ref.read(clientRuntimeProvider);
    final snapshot = runtime is RuntimeAttachmentProvider
        ? await (runtime as RuntimeAttachmentProvider).runtimeSnapshot()
        : null;
    final profile = snapshot?['profile'];
    if (profile is Map) {
      final nickname = profile['nickname']?.toString().trim() ?? '';
      final serviceAlive = snapshot?['serviceAlive'] == true;
      if (nickname.length >= 2 && mounted) {
        setState(() {
          _reattachedNickname = nickname;
          if (serviceAlive) _runningUnlocked = true;
        });
      }
    }
    if (mounted) {
      await ref.read(appControllerProvider.notifier).initialize();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final controller = ref.read(appControllerProvider.notifier);
    final code = await controller.refreshInviteCode();
    if (!mounted) return;
    if (code == null) {
      final error = ref.read(appControllerProvider).error;
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
      return;
    }
    final knownInboxIds = ref
        .read(appControllerProvider)
        .inbox
        .map((item) => item.id)
        .toSet();
    await showDialog<bool>(
      context: context,
      builder: (_) => PairingCodeDialog(
        initialCode: code.code,
        initialExpiresAt: code.expiresAt,
        refresh: controller.refreshInviteCode,
        onChanged: (_) {},
        checkRequest: () async {
          await controller.refreshData();
          final inbox = ref.read(appControllerProvider).inbox;
          return inbox.firstOrNullWhere(
            (item) =>
                !knownInboxIds.contains(item.id) &&
                item.can(PairingAvailableAction.accept),
          );
        },
        onAccept: (request) async {
          await controller.acceptPairing(request.id);
          final peerId = request.peer?.id;
          if (peerId == null || peerId.isEmpty) return false;
          for (var attempt = 0; attempt < 15; attempt += 1) {
            await controller.refreshData();
            if (ref
                .read(appControllerProvider)
                .contacts
                .any((contact) => contact.id == peerId)) {
              return true;
            }
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          return false;
        },
        onReject: (request) => controller.rejectPairing(request.id),
      ),
    );
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

  void _sendMessage(String? replyToMessageId) {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    unawaited(
      ref
          .read(appControllerProvider.notifier)
          .sendMessage(text, replyToMessageId: replyToMessageId),
    );
  }

  void _openAccount() {
    final state = ref.read(appControllerProvider);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountView(
          nickname: state.profile.nickname,
          installationId: state.identity.installationId,
          fingerprint: state.profile.fingerprint,
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsView(
          nickname: state.profile.nickname,
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

  Future<void> _editNickname() async {
    final appController = ref.read(appControllerProvider.notifier);
    final field = TextEditingController(
      text: ref.read(appControllerProvider).profile.nickname,
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
    final controller = ref.read(appControllerProvider.notifier);
    final connection = state.connectionReadiness;
    final summary = state.connectionSummary;
    final effectiveNickname = state.profile.nickname.trim().isNotEmpty
        ? state.profile.nickname
        : _reattachedNickname;
    final resolvedPhase = resolveLaunchPhase(
      profile: state.profile,
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
        : _onboardingUnlocked && state.profile.nickname.trim().isEmpty
        ? AppLaunchPhase.onboarding
        : resolvedPhase;

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

    final contacts = state.contacts;
    final conversations = state.conversations;
    final selectedContact = state.selectedContact(contacts, conversations);
    return MainShell(
      tab: switch (state.destination) {
        MainDestination.contacts => MobileTab.contacts,
        _ => MobileTab.chats,
      },
      nickname: effectiveNickname,
      fingerprint: state.profile.fingerprint,
      ownInvite: state.ownInvite?.code ?? '',
      status: summary.status,
      phase: summary.phase,
      latencyMs: summary.latencyMs,
      peerServerStatus: summary.peerServerStatus,
      contacts: contacts,
      conversations: conversations,
      messages: state.messages,
      selectedConversation: state.selectedConversationId,
      selectedContact: selectedContact,
      search: _search,
      composer: _composer,
      error: state.error,
      notice: state.notice,
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
      onRetryMessage: controller.retryMessage,
      onDeleteMessage: controller.deleteMessageLocal,
      onVerifyContact: controller.verifyContact,
      onUpdateContactSettings: controller.updateContactSettings,
      onBack: controller.closeConversation,
      onOpenAccount: _openAccount,
      onOpenSettings: _openSettings,
      onRetryTor: _showTransportStatus,
      typingContacts: state.typingContacts,
      onlineContacts: state.onlineContacts,
    );
  }
}
