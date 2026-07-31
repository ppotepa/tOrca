import 'package:flutter/material.dart';

import 'extensions/torchat_activity_theme.dart';
import 'families/current_theme.dart';
import 'families/retro_theme.dart';
import 'theme_preferences.dart';

abstract final class TorChatThemeRegistry {
  const TorChatThemeRegistry._();

  static ThemeData light(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => _withActivityTheme(
    switch (family) {
      TorChatThemeFamily.current => buildCurrentLightTheme(),
      TorChatThemeFamily.retro => buildRetroLightTheme(retroPalette),
    },
    family,
    retroPalette,
  );

  static ThemeData dark(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => _withActivityTheme(
    switch (family) {
      TorChatThemeFamily.current => buildCurrentDarkTheme(),
      TorChatThemeFamily.retro => buildRetroDarkTheme(retroPalette),
    },
    family,
    retroPalette,
  );

  static ThemeData _withActivityTheme(
    ThemeData theme,
    TorChatThemeFamily family,
    TorChatRetroPalette palette,
  ) {
    final extensions = theme.extensions.values.toList(growable: true);
    extensions.add(TorChatActivityTheme.forTheme(family, palette: palette));
    return theme.copyWith(extensions: extensions.cast<ThemeExtension<dynamic>>());
  }
}
