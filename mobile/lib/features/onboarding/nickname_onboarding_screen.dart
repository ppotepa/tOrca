import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/connection/connection_readiness.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_surface.dart';
import '../../locales/presentation/app_localizations_x.dart';

class NicknameOnboardingScreen extends ConsumerWidget {
  const NicknameOnboardingScreen({
    super.key,
    required this.controller,
    required this.connection,
    required this.error,
    required this.onSave,
  });

  final TextEditingController controller;
  final ConnectionReadiness connection;
  final String error;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final canSave = connection.onboardingReady;
    final saveState = ref.watch(
      uiOperationProvider(UiOperationKey.nicknameSave),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: BusySurface(
                state: saveState,
                label: l10n.nicknameSaving,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ThemedIcon(
                      canSave ? Icons.check_circle_outline : Icons.sync,
                      size: 64,
                      color: canSave
                          ? context.statusTheme.success
                          : context.statusTheme.warning,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      canSave
                          ? l10n.nicknameReady
                          : 'Przywracanie gotowości komunikacji…',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      canSave
                          ? l10n.nicknameDescription
                          : 'Wpisany nick zostanie zachowany. Zapis będzie dostępny po przywróceniu relaya i lokalnego onion.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      enabled: !saveState.busy,
                      maxLength: 32,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (canSave && !saveState.busy) onSave();
                      },
                      decoration: InputDecoration(
                        labelText: l10n.nicknameLabel,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          error,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.statusTheme.danger),
                        ),
                      ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: BusyActionButton(
                        busy: saveState.busy,
                        label: l10n.nicknameSave,
                        busyLabel: l10n.nicknameSaving,
                        onPressed: canSave ? onSave : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
