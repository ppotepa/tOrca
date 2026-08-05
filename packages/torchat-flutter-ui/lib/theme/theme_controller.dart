import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reduced_motion_policy.dart';
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
    final preferences = await _store.load();
    _applyMotionPolicy(preferences.reducedMotion);
    return preferences;
  }

  Future<void> setFamily(TorChatThemeFamily family) =>
      _update((value) => value.copyWith(family: family));

  Future<void> setBrightness(TorChatBrightnessMode brightness) =>
      _update((value) => value.copyWith(brightness: brightness));

  Future<void> setRetroPalette(TorChatRetroPalette palette) =>
      _update((value) => value.copyWith(retroPalette: palette));

  Future<void> setReducedMotion(bool reducedMotion) =>
      _update((value) => value.copyWith(reducedMotion: reducedMotion));

  Future<void> _update(
    TorChatThemePreferences Function(TorChatThemePreferences) mutate,
  ) async {
    final previous = state.value ?? const TorChatThemePreferences();
    final next = mutate(previous);
    _applyMotionPolicy(next.reducedMotion);
    state = AsyncData(next);
    try {
      await _store.save(next);
    } catch (_) {
      _applyMotionPolicy(previous.reducedMotion);
      state = AsyncData(previous);
      rethrow;
    }
  }

  void _applyMotionPolicy(bool reducedMotion) {
    TorChatMotionPolicy.setEnabled(reducedMotion);
  }
}
