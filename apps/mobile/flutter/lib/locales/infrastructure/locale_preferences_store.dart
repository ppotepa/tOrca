import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_locale_preference.dart';

class LocalePreferencesStore {
  LocalePreferencesStore(this._preferences);

  static const key = 'torchat.locale.preference';
  final SharedPreferences _preferences;

  static Future<LocalePreferencesStore> create() async =>
      LocalePreferencesStore(await SharedPreferences.getInstance());

  AppLocalePreference? load() =>
      AppLocalePreference.fromStorage(_preferences.getString(key));

  Future<void> save(AppLocalePreference preference) async {
    if (!await _preferences.setString(key, preference.storageValue)) {
      throw StateError('Unable to save language preference.');
    }
  }
}
