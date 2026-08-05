import 'package:flutter/material.dart';

import 'extensions/torchat_activity_theme.dart';
import 'extensions/torchat_chat_theme.dart';
import 'extensions/torchat_inbox_theme.dart';
import 'families/current_theme.dart';
import 'families/retro_theme.dart';
import 'theme_preferences.dart';

abstract final class TorChatThemeRegistry {
  const TorChatThemeRegistry._();

  static ThemeData light(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => _withActivityTheme(
    _withAccessibleColorScheme(switch (family) {
      TorChatThemeFamily.current => buildCurrentLightTheme(),
      TorChatThemeFamily.retro => buildRetroLightTheme(retroPalette),
    }),
    family,
    retroPalette,
  );

  static ThemeData dark(
    TorChatThemeFamily family, {
    TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
  }) => _withActivityTheme(
    _withAccessibleColorScheme(switch (family) {
      TorChatThemeFamily.current => buildCurrentDarkTheme(),
      TorChatThemeFamily.retro => buildRetroDarkTheme(retroPalette),
    }),
    family,
    retroPalette,
  );

  static ThemeData _withAccessibleColorScheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    final surface = _opaque(scheme.surface, Colors.white);
    Color foreground(Color background) =>
        accessibleForeground(background, backdrop: surface);

    final extensions = theme.extensions.values.toList(growable: true);
    final chat = theme.extension<TorChatChatTheme>();
    final inbox = theme.extension<TorChatInboxTheme>();
    extensions.removeWhere(
      (extension) =>
          extension is TorChatChatTheme || extension is TorChatInboxTheme,
    );
    if (chat != null) {
      extensions.add(
        chat.copyWith(
          incomingForeground: foreground(chat.incomingBubble),
          outgoingForeground: foreground(chat.outgoingBubble),
        ),
      );
    }
    if (inbox != null) {
      extensions.add(
        inbox.copyWith(
          acceptForeground: foreground(inbox.accept),
          rejectForeground: foreground(inbox.reject),
          archiveForeground: foreground(inbox.archive),
        ),
      );
    }
    return theme.copyWith(
      colorScheme: scheme.copyWith(
        onPrimary: foreground(scheme.primary),
        onSecondary: foreground(scheme.secondary),
        onTertiary: foreground(scheme.tertiary),
        onError: foreground(scheme.error),
        onPrimaryContainer: foreground(scheme.primaryContainer),
        onSecondaryContainer: foreground(scheme.secondaryContainer),
        onTertiaryContainer: foreground(scheme.tertiaryContainer),
        onErrorContainer: foreground(scheme.errorContainer),
      ),
      extensions: extensions.cast<ThemeExtension<dynamic>>(),
    );
  }

  static ThemeData _withActivityTheme(
    ThemeData theme,
    TorChatThemeFamily family,
    TorChatRetroPalette palette,
  ) {
    final extensions = theme.extensions.values.toList(growable: true);
    extensions.add(TorChatActivityTheme.forTheme(family, palette: palette));
    return theme.copyWith(
      extensions: extensions.cast<ThemeExtension<dynamic>>(),
    );
  }
}

@visibleForTesting
Color accessibleForeground(Color background, {Color backdrop = Colors.white}) {
  const dark = Color(0xff111111);
  const light = Colors.white;
  return contrastRatio(background, light, backdrop: backdrop) >=
          contrastRatio(background, dark, backdrop: backdrop)
      ? light
      : dark;
}

@visibleForTesting
double contrastRatio(
  Color first,
  Color second, {
  Color backdrop = Colors.white,
}) {
  final opaqueBackdrop = _opaque(backdrop, Colors.white);
  final opaqueFirst = _opaque(first, opaqueBackdrop);
  final opaqueSecond = _opaque(second, opaqueBackdrop);
  final firstLuminance = opaqueFirst.computeLuminance();
  final secondLuminance = opaqueSecond.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

Color _opaque(Color color, Color backdrop) => color.a >= 1
    ? color
    : Color.alphaBlend(color, backdrop).withValues(alpha: 1);
