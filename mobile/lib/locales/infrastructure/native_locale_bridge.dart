import 'package:flutter/services.dart';

import '../domain/app_locale_preference.dart';

class NativeLocaleBridge {
  static const _channel = MethodChannel('org.torchat/locale');

  Future<void> setPreference(AppLocalePreference preference) async {
    try {
      await _channel.invokeMethod<void>('setApplicationLocale', {
        'languageTag': preference == AppLocalePreference.system
            ? null
            : preference.locale!.languageCode,
      });
    } on MissingPluginException {
      // Desktop and test hosts do not provide the Android bridge.
    }
  }
}
