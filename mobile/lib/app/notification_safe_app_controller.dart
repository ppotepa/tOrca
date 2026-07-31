import 'pairing_recovery_app_controller.dart';
import 'app_controller_legacy.dart' as legacy;

class NotificationSafeAppController extends PairingRecoveryAppController {
  static const _legacyPairingNoticePrefix = 'Oczekujące zaproszenia:';
  bool _clearingLegacyNotice = false;

  @override
  legacy.AppState build() {
    final initial = super.build();
    listenSelf((_, next) {
      if (_clearingLegacyNotice ||
          !next.notice.startsWith(_legacyPairingNoticePrefix)) {
        return;
      }
      _clearingLegacyNotice = true;
      state = state.copyWith(notice: '');
      _clearingLegacyNotice = false;
    });
    return initial.notice.startsWith(_legacyPairingNoticePrefix)
        ? initial.copyWith(notice: '')
        : initial;
  }
}
