import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_preferences.dart';
import 'theme_preferences_store.dart';

final themeControllerProvider =
    AsyncNotifierProvider<ThemeController, TorChatThemePreferences>(
      ThemeController.new,
    );

class ThemeController extends AsyncNotifier<TorChatThemePreferences> {
  late ThemePreferencesStore _store;

  @override
  Future<TorChatThemePreferences> build() async {
    _store = await ThemePreferencesStore.create();
    return _store.load();
  }

  Future<void> setFamily(TorChatThemeFamily family) =>
      _update((value) => value.copyWith(family: family));

  Future<void> setBrightness(TorChatBrightnessMode brightness) =>
      _update((value) => value.copyWith(brightness: brightness));

  Future<void> setRetroPalette(TorChatRetroPalette palette) =>
      _update((value) => value.copyWith(retroPalette: palette));

  Future<void> _update(
    TorChatThemePreferences Function(TorChatThemePreferences) mutate,
  ) async {
    final next = mutate(state.value ?? const TorChatThemePreferences());
    state = AsyncData(next);
    await _store.save(next);
  }
}
