import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torchat_mobile/locales/domain/app_locale_preference.dart';
import 'package:torchat_mobile/locales/infrastructure/locale_preferences_store.dart';

void main() {
  test('stores stable language preference values', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await LocalePreferencesStore.create();

    expect(store.load(), isNull);
    await store.save(AppLocalePreference.polish);
    expect(store.load(), AppLocalePreference.polish);
    expect(
      (await SharedPreferences.getInstance()).getString(LocalePreferencesStore.key),
      'pl',
    );
  });

  test('unknown values do not become presentation labels', () async {
    SharedPreferences.setMockInitialValues({
      LocalePreferencesStore.key: 'Polski',
    });
    final store = await LocalePreferencesStore.create();

    expect(store.load(), isNull);
  });
}
