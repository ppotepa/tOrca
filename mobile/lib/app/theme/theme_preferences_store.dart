import 'package:shared_preferences/shared_preferences.dart';

import 'theme_preferences.dart';

class ThemePreferencesStore {
  ThemePreferencesStore(this._preferences);

  static const _familyKey = 'torchat.theme.family';
  static const _brightnessKey = 'torchat.theme.brightness';
  static const _retroPaletteKey = 'torchat.theme.retroPalette';
  static const _reducedMotionKey = 'torchat.accessibility.reducedMotion';

  final SharedPreferences _preferences;

  static Future<ThemePreferencesStore> create() async =>
      ThemePreferencesStore(await SharedPreferences.getInstance());

  Future<TorChatThemePreferences> load() async {
    final family = TorChatThemePreferences.parseFamily(
      _preferences.getString(_familyKey),
    );
    final brightness = TorChatThemePreferences.parseBrightness(
      _preferences.getString(_brightnessKey),
    );
    final retroPalette = TorChatThemePreferences.parseRetroPalette(
      _preferences.getString(_retroPaletteKey),
    );
    final reducedMotion = _preferences.getBool(_reducedMotionKey) ?? false;

    return TorChatThemePreferences(
      family: family,
      brightness: brightness,
      retroPalette: retroPalette,
      reducedMotion: reducedMotion,
    );
  }

  Future<void> save(TorChatThemePreferences value) async {
    await _preferences.setString(_familyKey, value.family.storageValue);
    await _preferences.setString(_brightnessKey, value.brightness.storageValue);
    await _preferences.setString(
      _retroPaletteKey,
      value.retroPalette.storageValue,
    );
    await _preferences.setBool(_reducedMotionKey, value.reducedMotion);
  }
}
