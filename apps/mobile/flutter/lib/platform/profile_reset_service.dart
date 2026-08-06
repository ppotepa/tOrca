import 'package:flutter/services.dart';

abstract interface class ProfileResetService {
  Future<void> resetLocalProfile();
}

final class MobileProfileResetService implements ProfileResetService {
  const MobileProfileResetService();

  static const MethodChannel _channel = MethodChannel('org.torchat/mobile');

  @override
  Future<void> resetLocalProfile() async {
    await _channel.invokeMethod<void>('resetLocalProfile');
  }
}

final class UnsupportedProfileResetService implements ProfileResetService {
  const UnsupportedProfileResetService();

  @override
  Future<void> resetLocalProfile() {
    throw UnsupportedError(
      'Local profile reset is unavailable on this platform.',
    );
  }
}
