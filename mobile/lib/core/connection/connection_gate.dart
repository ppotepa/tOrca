import '../models/domain.dart';
import 'connection_readiness.dart';

enum AppLaunchPhase { warming, onboarding, running }

AppLaunchPhase resolveLaunchPhase({
  required RuntimeProfile profile,
  required ConnectionReadiness connection,
}) {
  final hasNickname = profile.nickname.trim().length >= 2;

  // A returning user can enter the local shell without network access.
  if (hasNickname && connection.localCoreReady) {
    return AppLaunchPhase.running;
  }

  // A new user reaches onboarding only after the local onion endpoint and the
  // relay are both ready. Contact-level P2P sessions are intentionally not
  // part of this gate.
  if (!hasNickname && connection.onboardingReady) {
    return AppLaunchPhase.onboarding;
  }

  return AppLaunchPhase.warming;
}
