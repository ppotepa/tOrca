import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_flutter_ui/theme/theme_preferences.dart';
import 'package:torchat_flutter_ui/theme/theme_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('reduced motion defaults to disabled', () async {
    final store = await ThemePreferencesStore.create();

    final preferences = await store.load();

    expect(preferences.reducedMotion, isFalse);
  });

  test('reduced motion survives preference store recreation', () async {
    final store = await ThemePreferencesStore.create();
    const expected = TorChatThemePreferences(
      family: TorChatThemeFamily.retro,
      brightness: TorChatBrightnessMode.dark,
      retroPalette: TorChatRetroPalette.nord,
      reducedMotion: true,
    );

    await store.save(expected);
    final reloaded = await (await ThemePreferencesStore.create()).load();

    expect(reloaded.family, expected.family);
    expect(reloaded.brightness, expected.brightness);
    expect(reloaded.retroPalette, expected.retroPalette);
    expect(reloaded.reducedMotion, isTrue);
  });

  test('copyWith preserves reduced motion unless explicitly changed', () {
    const enabled = TorChatThemePreferences(reducedMotion: true);

    expect(
      enabled.copyWith(family: TorChatThemeFamily.retro).reducedMotion,
      isTrue,
    );
    expect(enabled.copyWith(reducedMotion: false).reducedMotion, isFalse);
  });
}
