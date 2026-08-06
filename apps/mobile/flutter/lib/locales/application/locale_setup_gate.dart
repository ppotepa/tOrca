import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_locale_preference.dart';
import 'locale_controller.dart';
import '../presentation/app_localizations_x.dart';

class LocaleSetupGate extends ConsumerWidget {
  const LocaleSetupGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeState = ref.watch(localeControllerProvider);
    return localeState.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.l10n.problemOperationFailed,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      data: (value) => value.setupCompleted
          ? child
          : _LanguageSetupScreen(
              onSelected: (preference) => ref
                  .read(localeControllerProvider.notifier)
                  .setPreference(preference),
            ),
    );
  }
}

class _LanguageSetupScreen extends StatelessWidget {
  const _LanguageSetupScreen({required this.onSelected});

  final ValueChanged<AppLocalePreference> onSelected;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.languageSetupTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(context.l10n.languageSetupDescription),
              const SizedBox(height: 24),
              for (final option in AppLocalePreference.values) ...[
                FilledButton(
                  onPressed: () => onSelected(option),
                  child: Text(switch (option) {
                    AppLocalePreference.system => context.l10n.languageSystem,
                    AppLocalePreference.polish =>
                      context.l10n.languagePolishNative,
                    AppLocalePreference.english =>
                      context.l10n.languageEnglishNative,
                  }),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
