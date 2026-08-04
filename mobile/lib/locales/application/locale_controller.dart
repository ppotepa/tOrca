import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_locale_preference.dart';
import '../infrastructure/locale_preferences_store.dart';
import '../infrastructure/native_locale_bridge.dart';

final localeControllerProvider =
    AsyncNotifierProvider<LocaleController, LocaleState>(LocaleController.new);

class LocaleState {
  const LocaleState({required this.preference, required this.setupCompleted});

  final AppLocalePreference preference;
  final bool setupCompleted;
}

class LocaleController extends AsyncNotifier<LocaleState> {
  late LocalePreferencesStore _store;
  final NativeLocaleBridge _nativeBridge = NativeLocaleBridge();

  @override
  Future<LocaleState> build() async {
    _store = await LocalePreferencesStore.create();
    final stored = _store.load();
    return LocaleState(
      preference: stored ?? AppLocalePreference.system,
      setupCompleted: stored != null,
    );
  }

  Future<void> setPreference(AppLocalePreference preference) async {
    await _store.save(preference);
    await _nativeBridge.setPreference(preference);
    state = AsyncData(LocaleState(preference: preference, setupCompleted: true));
  }
}
