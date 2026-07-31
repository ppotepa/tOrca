import 'package:flutter/material.dart';

import '../theme_preferences.dart';

enum TorChatActivityIndicatorKind { material, hourglass, terminal, blocks, dots }

@immutable
class TorChatActivityTheme extends ThemeExtension<TorChatActivityTheme> {
  const TorChatActivityTheme({
    required this.kind,
    required this.frames,
    required this.frameDuration,
    required this.overlayOpacity,
    required this.disabledOpacity,
    this.fontFamily,
  });

  factory TorChatActivityTheme.forTheme(
    TorChatThemeFamily family, {
    TorChatRetroPalette palette = TorChatRetroPalette.mocha,
  }) {
    if (family == TorChatThemeFamily.current) {
      return const TorChatActivityTheme(
        kind: TorChatActivityIndicatorKind.material,
        frames: <String>[],
        frameDuration: Duration(milliseconds: 700),
        overlayOpacity: .16,
        disabledOpacity: .55,
      );
    }
    return switch (palette) {
      TorChatRetroPalette.arcade => const TorChatActivityTheme(
          kind: TorChatActivityIndicatorKind.blocks,
          frames: ['▖', '▘', '▝', '▗'],
          frameDuration: Duration(milliseconds: 180),
          overlayOpacity: .22,
          disabledOpacity: .48,
          fontFamily: 'PressStart2P',
        ),
      TorChatRetroPalette.mocha => const TorChatActivityTheme(
          kind: TorChatActivityIndicatorKind.hourglass,
          frames: ['⌛', '⧖', '⧗', '⏳'],
          frameDuration: Duration(milliseconds: 320),
          overlayOpacity: .20,
          disabledOpacity: .52,
          fontFamily: 'PixelifySans',
        ),
      TorChatRetroPalette.gruvbox => const TorChatActivityTheme(
          kind: TorChatActivityIndicatorKind.terminal,
          frames: ['|', '/', '—', r'\\'],
          frameDuration: Duration(milliseconds: 180),
          overlayOpacity: .22,
          disabledOpacity: .50,
          fontFamily: 'PressStart2P',
        ),
      TorChatRetroPalette.nord => const TorChatActivityTheme(
          kind: TorChatActivityIndicatorKind.dots,
          frames: ['·  ', '·· ', '···'],
          frameDuration: Duration(milliseconds: 360),
          overlayOpacity: .18,
          disabledOpacity: .56,
          fontFamily: 'PixelifySans',
        ),
    };
  }

  final TorChatActivityIndicatorKind kind;
  final List<String> frames;
  final Duration frameDuration;
  final double overlayOpacity;
  final double disabledOpacity;
  final String? fontFamily;

  @override
  TorChatActivityTheme copyWith({
    TorChatActivityIndicatorKind? kind,
    List<String>? frames,
    Duration? frameDuration,
    double? overlayOpacity,
    double? disabledOpacity,
    String? fontFamily,
  }) => TorChatActivityTheme(
    kind: kind ?? this.kind,
    frames: frames ?? this.frames,
    frameDuration: frameDuration ?? this.frameDuration,
    overlayOpacity: overlayOpacity ?? this.overlayOpacity,
    disabledOpacity: disabledOpacity ?? this.disabledOpacity,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  @override
  TorChatActivityTheme lerp(
    covariant TorChatActivityTheme? other,
    double t,
  ) => other == null
      ? this
      : TorChatActivityTheme(
          kind: t < .5 ? kind : other.kind,
          frames: t < .5 ? frames : other.frames,
          frameDuration: t < .5 ? frameDuration : other.frameDuration,
          overlayOpacity: _lerp(overlayOpacity, other.overlayOpacity, t),
          disabledOpacity: _lerp(disabledOpacity, other.disabledOpacity, t),
          fontFamily: t < .5 ? fontFamily : other.fontFamily,
        );
}

double _lerp(double from, double to, double t) => from + (to - from) * t;

extension TorChatActivityThemeContext on BuildContext {
  TorChatActivityTheme get activityTheme =>
      Theme.of(this).extension<TorChatActivityTheme>() ??
      TorChatActivityTheme.forTheme(TorChatThemeFamily.current);
}
