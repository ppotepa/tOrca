import 'dart:ui';

import 'package:flutter/material.dart';

class TorChatChatTheme extends ThemeExtension<TorChatChatTheme> {
  const TorChatChatTheme({
    required this.incomingBubble,
    required this.incomingForeground,
    required this.outgoingBubble,
    required this.outgoingForeground,
    required this.metadataForeground,
    required this.composerBackground,
    required this.composerBorder,
    required this.unreadBackground,
    required this.unreadBorder,
    required this.bubbleRadius,
    required this.bubbleBorderWidth,
    required this.bubblePadding,
    required this.bubbleShadow,
  });

  final Color incomingBubble;
  final Color incomingForeground;
  final Color outgoingBubble;
  final Color outgoingForeground;
  final Color metadataForeground;
  final Color composerBackground;
  final Color composerBorder;
  final Color unreadBackground;
  final Color unreadBorder;
  final double bubbleRadius;
  final double bubbleBorderWidth;
  final EdgeInsets bubblePadding;
  final List<BoxShadow> bubbleShadow;

  @override
  ThemeExtension<TorChatChatTheme> copyWith({
    Color? incomingBubble,
    Color? incomingForeground,
    Color? outgoingBubble,
    Color? outgoingForeground,
    Color? metadataForeground,
    Color? composerBackground,
    Color? composerBorder,
    Color? unreadBackground,
    Color? unreadBorder,
    double? bubbleRadius,
    double? bubbleBorderWidth,
    EdgeInsets? bubblePadding,
    List<BoxShadow>? bubbleShadow,
  }) => TorChatChatTheme(
    incomingBubble: incomingBubble ?? this.incomingBubble,
    incomingForeground: incomingForeground ?? this.incomingForeground,
    outgoingBubble: outgoingBubble ?? this.outgoingBubble,
    outgoingForeground: outgoingForeground ?? this.outgoingForeground,
    metadataForeground: metadataForeground ?? this.metadataForeground,
    composerBackground: composerBackground ?? this.composerBackground,
    composerBorder: composerBorder ?? this.composerBorder,
    unreadBackground: unreadBackground ?? this.unreadBackground,
    unreadBorder: unreadBorder ?? this.unreadBorder,
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
    bubbleBorderWidth: bubbleBorderWidth ?? this.bubbleBorderWidth,
    bubblePadding: bubblePadding ?? this.bubblePadding,
    bubbleShadow: bubbleShadow ?? this.bubbleShadow,
  );

  @override
  ThemeExtension<TorChatChatTheme> lerp(
    covariant ThemeExtension<TorChatChatTheme>? other,
    double t,
  ) {
    if (other is! TorChatChatTheme) return this;
    return TorChatChatTheme(
      incomingBubble:
          Color.lerp(incomingBubble, other.incomingBubble, t) ?? incomingBubble,
      incomingForeground:
          Color.lerp(incomingForeground, other.incomingForeground, t) ??
          incomingForeground,
      outgoingBubble:
          Color.lerp(outgoingBubble, other.outgoingBubble, t) ?? outgoingBubble,
      outgoingForeground:
          Color.lerp(outgoingForeground, other.outgoingForeground, t) ??
          outgoingForeground,
      metadataForeground:
          Color.lerp(metadataForeground, other.metadataForeground, t) ??
          metadataForeground,
      composerBackground:
          Color.lerp(composerBackground, other.composerBackground, t) ??
          composerBackground,
      composerBorder:
          Color.lerp(composerBorder, other.composerBorder, t) ?? composerBorder,
      unreadBackground:
          Color.lerp(unreadBackground, other.unreadBackground, t) ??
          unreadBackground,
      unreadBorder:
          Color.lerp(unreadBorder, other.unreadBorder, t) ?? unreadBorder,
      bubbleRadius:
          lerpDouble(bubbleRadius, other.bubbleRadius, t) ?? bubbleRadius,
      bubbleBorderWidth:
          lerpDouble(bubbleBorderWidth, other.bubbleBorderWidth, t) ??
          bubbleBorderWidth,
      bubblePadding:
          EdgeInsets.lerp(bubblePadding, other.bubblePadding, t) ??
          bubblePadding,
      bubbleShadow: t < 0.5 ? bubbleShadow : other.bubbleShadow,
    );
  }
}

extension TorChatChatThemeContext on BuildContext {
  TorChatChatTheme get chatTheme =>
      Theme.of(this).extension<TorChatChatTheme>() ??
      (() {
        final scheme = Theme.of(this).colorScheme;
        return TorChatChatTheme(
          incomingBubble: scheme.surfaceContainerLow,
          incomingForeground: scheme.onSurface,
          outgoingBubble: scheme.surfaceContainer,
          outgoingForeground: scheme.onSurface,
          metadataForeground: scheme.onSurfaceVariant,
          composerBackground: scheme.surface,
          composerBorder: scheme.outline,
          unreadBackground: scheme.secondaryContainer,
          unreadBorder: scheme.secondary,
          bubbleRadius: 16,
          bubbleBorderWidth: 0,
          bubblePadding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
          bubbleShadow: const [],
        );
      })();
}
