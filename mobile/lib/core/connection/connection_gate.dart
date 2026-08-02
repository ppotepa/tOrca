import '../models/domain.dart';
import 'connection_readiness.dart';

enum AppLaunchPhase { warming, onboarding, running }

AppLaunchPhase resolveLaunchPhase({
  required RuntimeProfile profile,
  required ConnectionReadiness connection,
}) {
  final hasNickname = profile.nickname.trim().length >= 2;

  // Startup is a hard communication gate for returning users too. A retained
  // nickname must never bypass Tor, relay, peer listener or local onion
  // publication during a new runtime generation.
  if (hasNickname && connection.communicationReady) {
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
