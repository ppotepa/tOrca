import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/locale_controller.dart';
import '../domain/app_locale_preference.dart';
import 'app_localizations_x.dart';

class LanguagePicker extends ConsumerWidget {
  const LanguagePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference =
        ref.watch(localeControllerProvider).valueOrNull?.preference ??
        AppLocalePreference.system;
    return SegmentedButton<AppLocalePreference>(
      segments: [
        ButtonSegment(
          value: AppLocalePreference.system,
          label: Text(context.l10n.languageSystem),
        ),
        ButtonSegment(
          value: AppLocalePreference.polish,
          label: Text(context.l10n.languagePolish),
        ),
        ButtonSegment(
          value: AppLocalePreference.english,
          label: Text(context.l10n.languageEnglish),
        ),
      ],
      selected: {preference},
      showSelectedIcon: false,
      onSelectionChanged: (selected) {
        if (selected.isNotEmpty) {
          ref
              .read(localeControllerProvider.notifier)
              .setPreference(selected.first);
        }
      },
    );
  }
}
