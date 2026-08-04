import '../domain/user_problem.dart';
import '../domain/user_problem_code.dart';
import '../generated/app_localizations.dart';

String localizeProblem(
  AppLocalizations l10n,
  UserProblem problem,
) => switch (problem.code) {
  UserProblemCode.pairingWelcomeStale => l10n.problemPairingWelcomeStale,
  UserProblemCode.pairingCodeInvalid => l10n.problemPairingCodeInvalid,
  UserProblemCode.pairingRequiresRelay => l10n.problemPairingRequiresRelay,
  UserProblemCode.nicknameRequired => l10n.problemNicknameRequired,
  UserProblemCode.inviteCodeUnavailable => l10n.problemInviteCodeUnavailable,
  UserProblemCode.pairingGatewayUnavailable =>
    l10n.problemPairingGatewayUnavailable,
  UserProblemCode.secureConnectionPending =>
    l10n.problemSecureConnectionPending,
  UserProblemCode.connectionUnavailable => l10n.problemConnectionUnavailable,
  UserProblemCode.operationFailed => l10n.problemOperationFailed,
};
