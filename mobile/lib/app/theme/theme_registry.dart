import 'package:flutter/material.dart';

import 'families/current_theme.dart';
import 'families/retro_theme.dart';
import 'theme_preferences.dart';

abstract final class TorChatThemeRegistry {
  const TorChatThemeRegistry._();

  static ThemeData light(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => switch (family) {
    TorChatThemeFamily.current => buildCurrentLightTheme(),
    TorChatThemeFamily.retro => buildRetroLightTheme(retroPalette),
  };

  static ThemeData dark(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => switch (family) {
    TorChatThemeFamily.current => buildCurrentDarkTheme(),
    TorChatThemeFamily.retro => buildRetroDarkTheme(retroPalette),
  };
}
