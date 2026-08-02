import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelarticons/pixelarticons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_mobile/app/app_theme.dart';
import 'package:torchat_mobile/features/account/settings_view.dart';
import 'package:torchat_mobile/shared/widgets/identity_avatar.dart';
import 'package:torchat_mobile/shared/widgets/themed_switch_list_tile.dart';

void main() {
  test('retro palettes preserve semantic color roles', () {
    final backgrounds = <Color>{};
    for (final palette in TorChatRetroPalette.values) {
      final theme = buildRetroDarkTheme(palette);
      final status = _status(theme);
      backgrounds.add(theme.scaffoldBackgroundColor);

      expect(status.success.g, greaterThan(status.success.r));
      expect(status.danger.r, greaterThan(status.danger.g));
      expect(status.warning.r, greaterThan(status.warning.b));
      expect({status.success, status.warning, status.danger}.length, 3);
      expect(theme.colorScheme.primary, isNot(status.danger));
    }
    expect(backgrounds.length, TorChatRetroPalette.values.length);
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
    expect(
      _radius(
        theme.segmentedButtonTheme.style?.shape?.resolve({
          WidgetState.selected,
        }),
      ),
      BorderRadius.zero,
    );
  });

  testWidgets('retro switch is square while classic keeps Material switch', (
    tester,
  ) async {
    Widget app(ThemeData theme, Key key) => MaterialApp(
      key: key,
      theme: theme,
      home: Scaffold(
        body: ThemedSwitchListTile(
          title: const Text('Status'),
          value: true,
          onChanged: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(
      app(buildRetroDarkTheme(), const ValueKey('retro-switch')),
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(AnimatedAlign), findsOneWidget);

    await tester.pumpWidget(
      app(buildCurrentDarkTheme(), const ValueKey('classic-switch')),
    );
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('retro themed avatar never falls back to CircleAvatar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRetroDarkTheme(),
        home: const ThemedAvatar(child: Icon(Icons.person)),
      ),
    );
    expect(find.byType(CircleAvatar), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('classic-avatar'),
        theme: buildCurrentDarkTheme(),
        home: const ThemedAvatar(child: Icon(Icons.person)),
      ),
    );
    expect(find.byType(CircleAvatar), findsOneWidget);
  });

  testWidgets('retro palette selector fits a mobile settings screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    TorChatThemeFamily? selectedFamily;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildRetroDarkTheme(),
          home: SettingsView(
            nickname: 'torca',
            torStatus: 'online',
            themePreferences: const TorChatThemePreferences(),
            onThemeFamilyChanged: (family) => selectedFamily = family,
            onBrightnessChanged: (_) {},
            onRetroPaletteChanged: (_) {},
            onOpenTor: () {},
            onEditProfile: () {},
            onReset: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Mocha'), findsNothing);

    await tester.tap(find.text('Retro'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(selectedFamily, TorChatThemeFamily.retro);

    for (final palette in TorChatRetroPalette.values) {
      expect(find.text(palette.label), findsWidgets);
    }
    expect(tester.takeException(), isNull);
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
