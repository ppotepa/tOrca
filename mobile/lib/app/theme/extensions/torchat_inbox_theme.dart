import 'dart:ui';

import 'package:flutter/material.dart';

class TorChatInboxTheme extends ThemeExtension<TorChatInboxTheme> {
  const TorChatInboxTheme({
    required this.accept,
    required this.acceptForeground,
    required this.reject,
    required this.rejectForeground,
    required this.archive,
    required this.archiveForeground,
    required this.pending,
    required this.pendingBorderWidth,
    required this.completed,
    required this.actionRadius,
    required this.cardRadius,
    required this.cardBorderWidth,
    required this.actionMinWidth,
    required this.actionMinHeight,
    required this.actionPaddingHorizontal,
    required this.actionIconSize,
  });

  final Color accept;
  final Color acceptForeground;
  final Color reject;
  final Color rejectForeground;
  final Color archive;
  final Color archiveForeground;
  final Color pending;
  final double pendingBorderWidth;
  final Color completed;
  final double actionRadius;
  final double cardRadius;
  final double cardBorderWidth;
  final double actionMinWidth;
  final double actionMinHeight;
  final double actionPaddingHorizontal;
  final double actionIconSize;

  @override
  ThemeExtension<TorChatInboxTheme> copyWith({
    Color? accept,
    Color? acceptForeground,
    Color? reject,
    Color? rejectForeground,
    Color? archive,
    Color? archiveForeground,
    Color? pending,
    double? pendingBorderWidth,
    Color? completed,
    double? actionRadius,
    double? cardRadius,
    double? cardBorderWidth,
    double? actionMinWidth,
    double? actionMinHeight,
    double? actionPaddingHorizontal,
    double? actionIconSize,
  }) => TorChatInboxTheme(
    accept: accept ?? this.accept,
    acceptForeground: acceptForeground ?? this.acceptForeground,
    reject: reject ?? this.reject,
    rejectForeground: rejectForeground ?? this.rejectForeground,
    archive: archive ?? this.archive,
    archiveForeground: archiveForeground ?? this.archiveForeground,
    pending: pending ?? this.pending,
    pendingBorderWidth: pendingBorderWidth ?? this.pendingBorderWidth,
    completed: completed ?? this.completed,
    actionRadius: actionRadius ?? this.actionRadius,
    cardRadius: cardRadius ?? this.cardRadius,
    cardBorderWidth: cardBorderWidth ?? this.cardBorderWidth,
    actionMinWidth: actionMinWidth ?? this.actionMinWidth,
    actionMinHeight: actionMinHeight ?? this.actionMinHeight,
    actionPaddingHorizontal:
        actionPaddingHorizontal ?? this.actionPaddingHorizontal,
    actionIconSize: actionIconSize ?? this.actionIconSize,
  );

  @override
  ThemeExtension<TorChatInboxTheme> lerp(
    covariant ThemeExtension<TorChatInboxTheme>? other,
    double t,
  ) {
    if (other is! TorChatInboxTheme) return this;
    return TorChatInboxTheme(
      accept: Color.lerp(accept, other.accept, t) ?? accept,
      acceptForeground:
          Color.lerp(acceptForeground, other.acceptForeground, t) ??
          acceptForeground,
      reject: Color.lerp(reject, other.reject, t) ?? reject,
      rejectForeground:
          Color.lerp(rejectForeground, other.rejectForeground, t) ??
          rejectForeground,
      archive: Color.lerp(archive, other.archive, t) ?? archive,
      archiveForeground:
          Color.lerp(archiveForeground, other.archiveForeground, t) ??
          archiveForeground,
      pending: Color.lerp(pending, other.pending, t) ?? pending,
      pendingBorderWidth:
          lerpDouble(pendingBorderWidth, other.pendingBorderWidth, t) ??
          pendingBorderWidth,
      completed: Color.lerp(completed, other.completed, t) ?? completed,
      actionRadius:
          lerpDouble(actionRadius, other.actionRadius, t) ?? actionRadius,
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t) ?? cardRadius,
      cardBorderWidth:
          lerpDouble(cardBorderWidth, other.cardBorderWidth, t) ??
          cardBorderWidth,
      actionMinWidth:
          lerpDouble(actionMinWidth, other.actionMinWidth, t) ?? actionMinWidth,
      actionMinHeight:
          lerpDouble(actionMinHeight, other.actionMinHeight, t) ??
          actionMinHeight,
      actionPaddingHorizontal:
          lerpDouble(
            actionPaddingHorizontal,
            other.actionPaddingHorizontal,
            t,
          ) ??
          actionPaddingHorizontal,
      actionIconSize:
          lerpDouble(actionIconSize, other.actionIconSize, t) ?? actionIconSize,
    );
  }
}

extension TorChatInboxThemeContext on BuildContext {
  TorChatInboxTheme get inboxTheme =>
      Theme.of(this).extension<TorChatInboxTheme>() ??
      (() {
        final scheme = Theme.of(this).colorScheme;
        return TorChatInboxTheme(
          accept: scheme.primary,
          acceptForeground: scheme.onPrimary,
          reject: scheme.error,
          rejectForeground: scheme.onError,
          archive: scheme.surfaceContainerHighest,
          archiveForeground: scheme.onSurfaceVariant,
          pending: scheme.surface,
          pendingBorderWidth: 1.25,
          completed: scheme.surfaceContainerHighest,
          actionRadius: 14,
          cardRadius: 12,
          cardBorderWidth: 1,
          actionMinWidth: 68,
          actionMinHeight: 56,
          actionPaddingHorizontal: 24,
          actionIconSize: 18,
        );
      })();
}
