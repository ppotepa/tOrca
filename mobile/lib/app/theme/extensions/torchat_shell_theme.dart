import 'dart:ui';

import 'package:flutter/material.dart';

class TorChatShellTheme extends ThemeExtension<TorChatShellTheme> {
  const TorChatShellTheme({
    required this.background,
    required this.surface,
    required this.raisedSurface,
    required this.border,
    required this.selectedNavigationBackground,
    required this.selectedNavigationBorder,
    required this.navigationForeground,
    required this.selectedNavigationForeground,
    required this.panelRadius,
    required this.borderWidth,
    required this.listItemRadius,
    required this.listItemBorderWidth,
  });

  final Color background;
  final Color surface;
  final Color raisedSurface;
  final Color border;
  final Color selectedNavigationBackground;
  final Color selectedNavigationBorder;
  final Color navigationForeground;
  final Color selectedNavigationForeground;
  final double panelRadius;
  final double borderWidth;
  final double listItemRadius;
  final double listItemBorderWidth;

  @override
  ThemeExtension<TorChatShellTheme> copyWith({
    Color? background,
    Color? surface,
    Color? raisedSurface,
    Color? border,
    Color? selectedNavigationBackground,
    Color? selectedNavigationBorder,
    Color? navigationForeground,
    Color? selectedNavigationForeground,
    double? panelRadius,
    double? borderWidth,
    double? listItemRadius,
    double? listItemBorderWidth,
  }) => TorChatShellTheme(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    raisedSurface: raisedSurface ?? this.raisedSurface,
    border: border ?? this.border,
    selectedNavigationBackground:
        selectedNavigationBackground ?? this.selectedNavigationBackground,
    selectedNavigationBorder:
        selectedNavigationBorder ?? this.selectedNavigationBorder,
    navigationForeground: navigationForeground ?? this.navigationForeground,
    selectedNavigationForeground:
        selectedNavigationForeground ?? this.selectedNavigationForeground,
    panelRadius: panelRadius ?? this.panelRadius,
    borderWidth: borderWidth ?? this.borderWidth,
    listItemRadius: listItemRadius ?? this.listItemRadius,
    listItemBorderWidth: listItemBorderWidth ?? this.listItemBorderWidth,
  );

  @override
  ThemeExtension<TorChatShellTheme> lerp(
    covariant ThemeExtension<TorChatShellTheme>? other,
    double t,
  ) {
    if (other is! TorChatShellTheme) return this;
    return TorChatShellTheme(
      background: Color.lerp(background, other.background, t) ?? background,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      raisedSurface:
          Color.lerp(raisedSurface, other.raisedSurface, t) ?? raisedSurface,
      border: Color.lerp(border, other.border, t) ?? border,
      selectedNavigationBackground:
          Color.lerp(
            selectedNavigationBackground,
            other.selectedNavigationBackground,
            t,
          ) ??
          selectedNavigationBackground,
      selectedNavigationBorder:
          Color.lerp(
            selectedNavigationBorder,
            other.selectedNavigationBorder,
            t,
          ) ??
          selectedNavigationBorder,
      navigationForeground:
          Color.lerp(navigationForeground, other.navigationForeground, t) ??
          navigationForeground,
      selectedNavigationForeground:
          Color.lerp(
            selectedNavigationForeground,
            other.selectedNavigationForeground,
            t,
          ) ??
          selectedNavigationForeground,
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t) ?? panelRadius,
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t) ?? borderWidth,
      listItemRadius:
          lerpDouble(listItemRadius, other.listItemRadius, t) ?? listItemRadius,
      listItemBorderWidth:
          lerpDouble(listItemBorderWidth, other.listItemBorderWidth, t) ??
          listItemBorderWidth,
    );
  }
}

extension TorChatShellThemeContext on BuildContext {
  TorChatShellTheme get shellTheme =>
      Theme.of(this).extension<TorChatShellTheme>() ??
      (() {
        final scheme = Theme.of(this).colorScheme;
        return TorChatShellTheme(
          background: scheme.surface,
          surface: scheme.surfaceContainerLowest,
          raisedSurface: scheme.surfaceContainer,
          border: scheme.outline,
          selectedNavigationBackground: scheme.secondaryContainer,
          selectedNavigationBorder: scheme.primary,
          navigationForeground: scheme.onSurfaceVariant,
          selectedNavigationForeground: scheme.onSurface,
          panelRadius: 0,
          borderWidth: 1,
          listItemRadius: 0,
          listItemBorderWidth: 1,
        );
      })();
}
