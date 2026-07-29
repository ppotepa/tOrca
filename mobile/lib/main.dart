import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_controller.dart';
import 'app/app_theme.dart';
import 'client_runtime.dart';
import 'features/account/account_view.dart';
import 'features/account/settings_view.dart';
import 'features/invites/invite_scanner.dart';
import 'features/shell/main_shell.dart';
import 'features/onboarding/onboarding_views.dart';

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
      theme: TorChatThemeRegistry.light(preferences.family),
      darkTheme: TorChatThemeRegistry.dark(preferences.family),
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

class _ControllerHomePageState extends ConsumerState<ControllerHomePage> {
  final _search = TextEditingController();
  final _composer = TextEditingController();
  final _nickname = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(appControllerProvider.notifier).initialize();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _composer.dispose();
    _nickname.dispose();
    super.dispose();
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
    final used = await showDialog<bool>(
      context: context,
      builder: (_) => PairingCodeDialog(
        initialCode: code.code,
        initialExpiresAt: code.expiresAt,
        refresh: controller.refreshInviteCode,
        onChanged: (_) {},
        checkUsed: () async {
          await controller.refreshData(announceChanges: true);
          final inbox = ref.read(appControllerProvider).inbox;
          return inbox.any(
            (item) =>
                !knownInboxIds.contains(item.id) &&
                item.can(PairingAvailableAction.accept),
          );
        },
      ),
    );
    if (!mounted || used != true) return;
    controller.selectDestination(MainDestination.inbox);
  }

  Future<void> _scanInvite() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const InviteScannerPage()),
    );
    if (!mounted || value == null) return;
    await ref.read(appControllerProvider.notifier).submitPairingCode(value);
  }

  void _sendMessage() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    unawaited(ref.read(appControllerProvider.notifier).sendMessage(text));
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsView(
          nickname: state.profile.nickname,
          torStatus: state.transport.label,
          themePreferences: ref.read(themeControllerProvider).valueOrNull ??
              const TorChatThemePreferences(),
          onThemeFamilyChanged: (family) {
            unawaited(
              ref.read(themeControllerProvider.notifier).setFamily(family),
            );
          },
          onBrightnessChanged: (brightness) {
            unawaited(
              ref.read(themeControllerProvider.notifier).setBrightness(brightness),
            );
          },
          onOpenTor: () {
            Navigator.pop(context);
            ref.read(appControllerProvider.notifier).retryTor();
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
    if (state.screen == ControllerScreen.boot) {
      return BootScreen(
        phase: state.transport.phase,
        status: state.transport.label.isEmpty
            ? 'Uruchamianie Tor…'
            : state.transport.label,
        detail: state.transport.detail,
        progress: state.transport.progress,
        error: state.error,
        retry: controller.retryTor,
        connecting: !state.transport.failed,
      );
    }
    if (state.screen == ControllerScreen.nickname) {
      return NicknameScreen(
        controller: _nickname,
        transport: state.transport,
        error: state.error,
        onSave: () async {
          await controller.setNickname(_nickname.text);
          if (ref.read(appControllerProvider).screen !=
              ControllerScreen.nickname) {
            _nickname.clear();
          }
        },
      );
    }

    final contacts = state.contacts;
    final conversations = state.conversations;
    final requests = state.pairingRequests();
    final selectedContact = state.selectedContact(contacts, conversations);
    return MainShell(
      tab: switch (state.destination) {
        MainDestination.contacts => MobileTab.contacts,
        MainDestination.inbox => MobileTab.inbox,
        _ => MobileTab.chats,
      },
      nickname: state.profile.nickname,
      fingerprint: state.profile.fingerprint,
      ownInvite: state.ownInvite?.code ?? '',
      status: state.transport.label,
      phase: state.transport.phase,
      latencyMs: state.transport.latencyMs,
      contacts: contacts,
      conversations: conversations,
      messages: state.messages,
      selectedConversation: state.selectedConversationId,
      selectedContact: selectedContact,
      inbox: requests,
      outbox: state.outbox,
      activeInviteCount: state.activeInviteCount,
      search: _search,
      composer: _composer,
      error: state.error,
      notice: state.notice,
      action: state.action,
      onTab: (tab) => controller.selectDestination(switch (tab) {
        MobileTab.contacts => MainDestination.contacts,
        MobileTab.inbox => MainDestination.inbox,
        MobileTab.chats => MainDestination.chats,
      }),
      onSearch: () => controller.submitPairingCode(_search.text),
      onOpenConversation: controller.openConversation,
      onStartConversation: controller.openOrStartConversation,
      onScanInvite: _scanInvite,
      onShowInvite: _showInvite,
      onSend: _sendMessage,
      onVerifyContact: controller.verifyContact,
      onBack: controller.closeConversation,
      onAcceptRequest: (request) => controller.acceptPairing(request.id),
      onRejectRequest: (request) => controller.rejectPairing(request.id),
      onArchiveRequest: (request) => controller.archiveInvite(request.id),
      onCancelRequest: (request) => controller.cancelPairing(request.id),
      onOpenAccount: _openAccount,
      onOpenSettings: _openSettings,
      onRetryTor: controller.retryTor,
    );
  }
}
