enum TorChatThemeFamily { current, retro }

enum TorChatBrightnessMode { system, light, dark }

final class TorChatThemePreferences {
  const TorChatThemePreferences({
    this.family = TorChatThemeFamily.current,
    this.brightness = TorChatBrightnessMode.system,
  });

  final TorChatThemeFamily family;
  final TorChatBrightnessMode brightness;

  TorChatThemePreferences copyWith({
    TorChatThemeFamily? family,
    TorChatBrightnessMode? brightness,
  }) => TorChatThemePreferences(
    family: family ?? this.family,
    brightness: brightness ?? this.brightness,
  );

  static TorChatThemeFamily parseFamily(String? value) => switch (value) {
    'retro' => TorChatThemeFamily.retro,
    _ => TorChatThemeFamily.current,
  };

  static TorChatBrightnessMode parseBrightness(String? value) =>
      switch (value) {
        'light' => TorChatBrightnessMode.light,
        'dark' => TorChatBrightnessMode.dark,
        _ => TorChatBrightnessMode.system,
      };
}

extension TorChatThemeFamilyStorage on TorChatThemeFamily {
  String get storageValue => switch (this) {
    TorChatThemeFamily.current => 'current',
    TorChatThemeFamily.retro => 'retro',
  };
}

extension TorChatBrightnessModeStorage on TorChatBrightnessMode {
  String get storageValue => switch (this) {
    TorChatBrightnessMode.system => 'system',
    TorChatBrightnessMode.light => 'light',
    TorChatBrightnessMode.dark => 'dark',
  };
}
