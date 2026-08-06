import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:torchat_flutter_ui/app_theme.dart';

import '../client_runtime.dart';
import '../core/connection/connection_gate.dart';
import '../features/account/account_view.dart';
import '../features/account/settings_view.dart';
import '../features/chats/composer_draft.dart';
import '../features/connection/connection_center_sheet.dart';
import '../features/invites/invite_scanner.dart';
import '../features/onboarding/connection_warmup_screen.dart';
import '../features/onboarding/nickname_onboarding_screen.dart';
import '../features/onboarding/onboarding_views.dart';
import '../features/pairing/pairing_ui_coordinator.dart';
import '../features/shell/main_shell.dart';
import '../locales/application/locale_controller.dart';
import '../locales/application/locale_setup_gate.dart';
import '../locales/generated/app_localizations.dart';
import '../locales/presentation/app_localizations_x.dart';
import '../locales/presentation/state_problem_localizer.dart';
import '../platform/platform_services.dart';
import '../platform/providers/platform_port_providers.dart';
import '../shared/widgets/toast_host.dart';
import 'app_controller.dart';
import 'application_snapshot_provider.dart';
import 'conversation_navigation_intent.dart';
import 'notifications/ui_notification_center.dart';

part 'application_dialogs.dart';
part 'application_root.dart';

class TorcaApp extends StatelessWidget {
  TorcaApp({super.key, this.runtime, PlatformServices? platformServices})
    : platformServices = platformServices ?? PlatformServices();

  final ClientRuntime? runtime;
  final PlatformServices platformServices;

  @override
  Widget build(BuildContext context) {
    final resolvedRuntime = runtime ?? platformServices.runtimeBridgeFactory();
    return ProviderScope(
      overrides: [
        platformServicesProvider.overrideWithValue(platformServices),
        clientRuntimeProvider.overrideWithValue(resolvedRuntime),
      ],
      child: const _TorcaAppView(),
    );
  }
}

/// Temporary public constructor name retained for existing desktop embedding.
/// Both entrypoints use the same Torca application shell.
class TorChatMobileApp extends TorcaApp {
  TorChatMobileApp({super.key, super.runtime, super.platformServices});
}

class _TorcaAppView extends ConsumerWidget {
  const _TorcaAppView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeControllerProvider);
    final preferences =
        themeState.valueOrNull ?? const TorChatThemePreferences();
    final localePreference = ref
        .watch(localeControllerProvider)
        .valueOrNull
        ?.preference;

    return MaterialApp(
      locale: localePreference?.locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
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
      home: const LocaleSetupGate(child: ControllerHomePage()),
    );
  }
}
