export 'theme/torchat_theme.dart';

import 'package:flutter/material.dart';

import 'theme/theme_preferences.dart';
import 'theme/theme_registry.dart';

ThemeData buildTorChatTheme({
  TorChatThemeFamily family = TorChatThemeFamily.current,
  TorChatBrightnessMode brightness = TorChatBrightnessMode.system,
  TorChatRetroPalette retroPalette = TorChatRetroPalette.mocha,
}) => switch (brightness) {
  TorChatBrightnessMode.light => TorChatThemeRegistry.light(
    family,
    retroPalette: retroPalette,
  ),
  TorChatBrightnessMode.dark => TorChatThemeRegistry.dark(
    family,
    retroPalette: retroPalette,
  ),
  _ =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark
        ? TorChatThemeRegistry.dark(family, retroPalette: retroPalette)
        : TorChatThemeRegistry.light(family, retroPalette: retroPalette),
};
