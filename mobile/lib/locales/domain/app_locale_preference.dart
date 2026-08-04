import 'dart:ui';

enum AppLocalePreference {
  system('system'),
  english('en'),
  polish('pl');

  const AppLocalePreference(this.storageValue);

  final String storageValue;

  Locale? get locale => switch (this) {
    AppLocalePreference.system => null,
    AppLocalePreference.english => const Locale('en'),
    AppLocalePreference.polish => const Locale('pl'),
  };

  static AppLocalePreference? fromStorage(String? value) => switch (value) {
    'system' => AppLocalePreference.system,
    'en' => AppLocalePreference.english,
    'pl' => AppLocalePreference.polish,
    _ => null,
  };
}
