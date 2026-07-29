import 'dart:ui';

import 'package:flutter/material.dart';

class TorChatEffectsTheme extends ThemeExtension<TorChatEffectsTheme> {
  const TorChatEffectsTheme({
    required this.raisedShadow,
    required this.alertGlow,
    required this.pressOffset,
    required this.pixelated,
    required this.scanlines,
  });

  final List<BoxShadow> raisedShadow;
  final List<BoxShadow> alertGlow;
  final double pressOffset;
  final bool pixelated;
  final bool scanlines;

  @override
  ThemeExtension<TorChatEffectsTheme> copyWith({
    List<BoxShadow>? raisedShadow,
    List<BoxShadow>? alertGlow,
    double? pressOffset,
    bool? pixelated,
    bool? scanlines,
  }) => TorChatEffectsTheme(
    raisedShadow: raisedShadow ?? this.raisedShadow,
    alertGlow: alertGlow ?? this.alertGlow,
    pressOffset: pressOffset ?? this.pressOffset,
    pixelated: pixelated ?? this.pixelated,
    scanlines: scanlines ?? this.scanlines,
  );

  @override
  ThemeExtension<TorChatEffectsTheme> lerp(
    covariant ThemeExtension<TorChatEffectsTheme>? other,
    double t,
  ) {
    if (other is! TorChatEffectsTheme) return this;
    return TorChatEffectsTheme(
      raisedShadow: t < 0.5 ? raisedShadow : other.raisedShadow,
      alertGlow: t < 0.5 ? alertGlow : other.alertGlow,
      pressOffset: lerpDouble(pressOffset, other.pressOffset, t) ?? pressOffset,
      pixelated: t < 0.5 ? pixelated : other.pixelated,
      scanlines: t < 0.5 ? scanlines : other.scanlines,
    );
  }
}

extension TorChatEffectsThemeContext on BuildContext {
  TorChatEffectsTheme get effectsTheme =>
      Theme.of(this).extension<TorChatEffectsTheme>() ??
      (() {
        final shadowColor = Theme.of(this).shadowColor.withValues(alpha: 0.18);
        return TorChatEffectsTheme(
          raisedShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          alertGlow: [BoxShadow(color: shadowColor, blurRadius: 6)],
          pressOffset: 2,
          pixelated: false,
          scanlines: false,
        );
      })();
}
