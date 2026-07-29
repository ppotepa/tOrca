import 'package:flutter/material.dart';

import '../extensions/torchat_chat_theme.dart';
import '../extensions/torchat_effects_theme.dart';
import '../extensions/torchat_inbox_theme.dart';
import '../extensions/torchat_shell_theme.dart';
import '../extensions/torchat_status_theme.dart';

const currentDarkAccent = Color(0xff61d095);
const currentDarkBackground = Color(0xff101318);
const currentDarkSurface = Color(0xff171c23);
const currentDarkSurfaceRaised = Color(0xff1e252e);
const currentDarkLine = Color(0xff303944);
const currentDarkText = Color(0xffedf2f7);
const currentDarkMuted = Color(0xff929eab);
const currentDarkWarning = Color(0xffe9b85d);
const currentDarkDanger = Color(0xffef7180);

const _currentIncomingBubble = Color(0xff202832);
const _currentOutgoingBubble = Color(0xff244c3d);

ThemeData buildCurrentDarkTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: currentDarkAccent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: currentDarkAccent,
        surface: currentDarkSurface,
        outline: currentDarkLine,
      );

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: currentDarkBackground,
    useMaterial3: true,
    dividerTheme: const DividerThemeData(
      color: currentDarkLine,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: currentDarkSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: currentDarkLine),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: currentDarkSurface,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: currentDarkLine),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: currentDarkLine),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: currentDarkAccent, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: currentDarkSurface,
      indicatorColor: const Color(0x2561d095),
      labelTextStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    ),
    extensions: [
      TorChatChatTheme(
        incomingBubble: _currentIncomingBubble,
        incomingForeground: currentDarkText,
        outgoingBubble: _currentOutgoingBubble,
        outgoingForeground: currentDarkText,
        metadataForeground: const Color(0xffa7becf),
        composerBackground: currentDarkSurfaceRaised,
        composerBorder: currentDarkLine,
        unreadBackground: const Color(0x21ffcc80),
        unreadBorder: const Color(0x40ffcc80),
        bubbleRadius: 16,
        bubbleBorderWidth: 0,
        bubblePadding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
        bubbleShadow: const [],
      ),
      TorChatShellTheme(
        background: currentDarkBackground,
        surface: currentDarkSurface,
        raisedSurface: currentDarkSurfaceRaised,
        border: currentDarkLine,
        selectedNavigationBackground: const Color(0x1861d095),
        selectedNavigationBorder: currentDarkAccent,
        navigationForeground: currentDarkMuted,
        selectedNavigationForeground: currentDarkText,
        panelRadius: 0,
        borderWidth: 1,
        listItemRadius: 12,
        listItemBorderWidth: 1,
      ),
      TorChatInboxTheme(
        accept: currentDarkAccent,
        acceptForeground: currentDarkText,
        reject: currentDarkDanger,
        rejectForeground: currentDarkText,
        archive: const Color(0xff2c3a44),
        archiveForeground: currentDarkText,
        pending: currentDarkSurface,
        pendingBorderWidth: 1.5,
        completed: const Color(0xff2f3d47),
        actionRadius: 12,
        cardRadius: 0,
        cardBorderWidth: 1,
        actionMinWidth: 68,
        actionMinHeight: 56,
        actionPaddingHorizontal: 24,
        actionIconSize: 20,
      ),
      TorChatStatusTheme(
        success: currentDarkAccent,
        warning: currentDarkWarning,
        danger: currentDarkDanger,
        offline: const Color(0xff6c757d),
        statusBackground: const Color(0x1ad7973c),
        statusForeground: currentDarkWarning,
        statusBorder: currentDarkLine,
      ),
      TorChatEffectsTheme(
        raisedShadow: const [],
        alertGlow: const [
          BoxShadow(
            color: Color(0x4de9b85d),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
        pressOffset: 2,
        pixelated: false,
        scanlines: false,
      ),
    ],
  );
}

ThemeData buildCurrentLightTheme() {
  const incoming = Color(0xffe4e8e3);
  const outgoing = Color(0xffcde9da);
  const primary = Color(0xff187a52);
  const background = Color(0xfff2f0e9);
  const surface = Color(0xfffaf9f5);
  const raisedSurface = Color(0xffffffff);
  const border = Color(0xffc8cec7);
  const text = Color(0xff17201b);
  const muted = Color(0xff657169);
  const warning = Color(0xff9b6500);
  const danger = Color(0xffb72f45);

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: primary,
        surface: surface,
        outline: border,
        onSurface: text,
        onPrimary: text,
      );

  return ThemeData(
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    useMaterial3: true,
    dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: primary, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: const Color(0x22187a52),
      labelTextStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    ),
    extensions: [
      TorChatChatTheme(
        incomingBubble: incoming,
        incomingForeground: text,
        outgoingBubble: outgoing,
        outgoingForeground: const Color(0xff123c29),
        metadataForeground: muted,
        composerBackground: surface,
        composerBorder: border,
        unreadBackground: const Color(0xfffff2cd),
        unreadBorder: const Color(0xffc88400),
        bubbleRadius: 16,
        bubbleBorderWidth: 0,
        bubblePadding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
        bubbleShadow: const [],
      ),
      TorChatShellTheme(
        background: background,
        surface: surface,
        raisedSurface: raisedSurface,
        border: border,
        selectedNavigationBackground: const Color(0x20187a52),
        selectedNavigationBorder: primary,
        navigationForeground: muted,
        selectedNavigationForeground: text,
        panelRadius: 0,
        borderWidth: 1,
        listItemRadius: 12,
        listItemBorderWidth: 1,
      ),
      TorChatInboxTheme(
        accept: primary,
        acceptForeground: text,
        reject: danger,
        rejectForeground: text,
        archive: muted,
        archiveForeground: text,
        pending: surface,
        pendingBorderWidth: 1.5,
        completed: Color(0xffe6ece6),
        actionRadius: 12,
        cardRadius: 0,
        cardBorderWidth: 1,
        actionMinWidth: 68,
        actionMinHeight: 56,
        actionPaddingHorizontal: 24,
        actionIconSize: 20,
      ),
      TorChatStatusTheme(
        success: primary,
        warning: warning,
        danger: danger,
        offline: const Color(0xff7a7a7a),
        statusBackground: const Color(0x1a187a52),
        statusForeground: warning,
        statusBorder: border,
      ),
      TorChatEffectsTheme(
        raisedShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
        alertGlow: const [
          BoxShadow(
            color: Color(0x4de9b85d),
            blurRadius: 6,
            offset: Offset(0, 1),
          ),
        ],
        pressOffset: 2,
        pixelated: false,
        scanlines: false,
      ),
    ],
  );
}
