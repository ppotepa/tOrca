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
    _withAccessibleColorScheme(
      switch (family) {
        TorChatThemeFamily.current => buildCurrentLightTheme(),
        TorChatThemeFamily.retro => buildRetroLightTheme(retroPalette),
      },
    ),
    family,
    retroPalette,
  );

  static ThemeData dark(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => _withActivityTheme(
    _withAccessibleColorScheme(
      switch (family) {
        TorChatThemeFamily.current => buildCurrentDarkTheme(),
        TorChatThemeFamily.retro => buildRetroDarkTheme(retroPalette),
      },
    ),
    family,
    retroPalette,
  );

  static ThemeData _withAccessibleColorScheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    return theme.copyWith(
      colorScheme: scheme.copyWith(
        onPrimary: accessibleForeground(scheme.primary),
        onSecondary: accessibleForeground(scheme.secondary),
        onTertiary: accessibleForeground(scheme.tertiary),
        onError: accessibleForeground(scheme.error),
        onPrimaryContainer: accessibleForeground(scheme.primaryContainer),
        onSecondaryContainer: accessibleForeground(scheme.secondaryContainer),
        onTertiaryContainer: accessibleForeground(scheme.tertiaryContainer),
        onErrorContainer: accessibleForeground(scheme.errorContainer),
      ),
    );
  }

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

@visibleForTesting
Color accessibleForeground(Color background) {
  const dark = Color(0xff111111);
  const light = Colors.white;
  return contrastRatio(background, light) >= contrastRatio(background, dark)
      ? light
      : dark;
}

@visibleForTesting
double contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
