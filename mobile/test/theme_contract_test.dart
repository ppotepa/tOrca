import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelarticons/pixelarticons.dart';
import 'package:torchat_mobile/app/app_theme.dart';

void main() {
  test('retro preserves current semantic status colors', () {
    final currentDark = buildCurrentDarkTheme();
    final retroDark = buildRetroDarkTheme();
    final currentLight = buildCurrentLightTheme();
    final retroLight = buildRetroLightTheme();

    expect(_status(retroDark).success, _status(currentDark).success);
    expect(_status(retroDark).warning, _status(currentDark).warning);
    expect(_status(retroDark).danger, _status(currentDark).danger);
    expect(
      _status(retroDark).statusBackground,
      _status(currentDark).statusBackground,
    );
    expect(_status(retroLight).success, _status(currentLight).success);
    expect(_status(retroLight).warning, _status(currentLight).warning);
    expect(_status(retroLight).danger, _status(currentLight).danger);
    expect(
      _status(retroLight).statusBackground,
      _status(currentLight).statusBackground,
    );
  });

  test('retro uses rectangular component geometry', () {
    final theme = buildRetroDarkTheme();

    expect(_radius(theme.cardTheme.shape), BorderRadius.zero);
    expect(_radius(theme.chipTheme.shape), BorderRadius.zero);
    expect(_radius(theme.dialogTheme.shape), BorderRadius.zero);
    expect(_radius(theme.navigationBarTheme.indicatorShape), BorderRadius.zero);
    expect(
      (theme.inputDecorationTheme.border! as OutlineInputBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(theme.extension<TorChatEffectsTheme>()!.pixelated, isTrue);
  });

  testWidgets('themed icons preserve meaning and switch glyph family', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('current-theme'),
        theme: buildCurrentLightTheme(),
        home: const ThemedIcon(Icons.chat_bubble_outline),
      ),
    );
    expect(
      tester.widget<Icon>(find.byType(Icon)).icon,
      Icons.chat_bubble_outline,
    );

    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('retro-theme'),
        theme: buildRetroLightTheme(),
        home: const ThemedIcon(Icons.chat_bubble_outline),
      ),
    );
    expect(tester.widget<Icon>(find.byType(Icon)).icon, Pixel.chat);
  });
}

TorChatStatusTheme _status(ThemeData theme) =>
    theme.extension<TorChatStatusTheme>()!;

BorderRadius? _radius(ShapeBorder? shape) =>
    (shape as RoundedRectangleBorder?)?.borderRadius as BorderRadius?;
