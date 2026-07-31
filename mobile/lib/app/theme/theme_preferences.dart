enum TorChatThemeFamily { current, retro }

enum TorChatBrightnessMode { system, light, dark }

enum TorChatRetroPalette { arcade, mocha, gruvbox, nord }

final class TorChatThemePreferences {
  const TorChatThemePreferences({
    this.family = TorChatThemeFamily.current,
    this.brightness = TorChatBrightnessMode.system,
    this.retroPalette = TorChatRetroPalette.mocha,
    this.reducedMotion = false,
  });

  final TorChatThemeFamily family;
  final TorChatBrightnessMode brightness;
  final TorChatRetroPalette retroPalette;
  final bool reducedMotion;

  TorChatThemePreferences copyWith({
    TorChatThemeFamily? family,
    TorChatBrightnessMode? brightness,
    TorChatRetroPalette? retroPalette,
    bool? reducedMotion,
  }) => TorChatThemePreferences(
    family: family ?? this.family,
    brightness: brightness ?? this.brightness,
    retroPalette: retroPalette ?? this.retroPalette,
    reducedMotion: reducedMotion ?? this.reducedMotion,
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

  static TorChatRetroPalette parseRetroPalette(String? value) =>
      switch (value) {
        'arcade' => TorChatRetroPalette.arcade,
        'gruvbox' => TorChatRetroPalette.gruvbox,
        'nord' => TorChatRetroPalette.nord,
        _ => TorChatRetroPalette.mocha,
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

extension TorChatRetroPaletteStorage on TorChatRetroPalette {
  String get storageValue => switch (this) {
    TorChatRetroPalette.arcade => 'arcade',
    TorChatRetroPalette.mocha => 'mocha',
    TorChatRetroPalette.gruvbox => 'gruvbox',
    TorChatRetroPalette.nord => 'nord',
  };

  String get label => switch (this) {
    TorChatRetroPalette.arcade => 'Arcade',
    TorChatRetroPalette.mocha => 'Mocha',
    TorChatRetroPalette.gruvbox => 'Gruvbox',
    TorChatRetroPalette.nord => 'Nord',
  };
}
