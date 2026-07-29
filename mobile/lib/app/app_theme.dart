export 'theme/torchat_theme.dart';

import 'package:flutter/material.dart';

import 'theme/theme_preferences.dart';
import 'theme/theme_registry.dart';

ThemeData buildTorChatTheme({
  TorChatThemeFamily family = TorChatThemeFamily.current,
  TorChatBrightnessMode brightness = TorChatBrightnessMode.system,
}) => switch (brightness) {
  TorChatBrightnessMode.light => TorChatThemeRegistry.light(family),
  TorChatBrightnessMode.dark => TorChatThemeRegistry.dark(family),
  _ =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark
        ? TorChatThemeRegistry.dark(family)
        : TorChatThemeRegistry.light(family),
};
