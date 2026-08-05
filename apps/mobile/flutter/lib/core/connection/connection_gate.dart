import '../models/domain.dart';
import 'connection_readiness.dart';

enum AppLaunchPhase { warming, onboarding, running }

AppLaunchPhase resolveLaunchPhase({
  required RuntimeProfile profile,
  required ConnectionReadiness connection,
}) {
  final hasNickname = profile.nickname.trim().length >= 2;

  // Local data is sufficient to open the shell. Network capabilities are
  // represented separately by ConnectionReadiness and can recover in the
  // background without blocking history/settings.
  if (hasNickname && connection.localCoreReady) {
    return AppLaunchPhase.running;
  }

  if (!hasNickname && connection.localCoreReady) {
    return AppLaunchPhase.onboarding;
  }

  return AppLaunchPhase.warming;
}
