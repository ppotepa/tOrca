import '../domain/user_problem.dart';
import '../generated/app_localizations.dart';
import 'problem_localizer.dart';

/// Resolves an application problem into user-facing localized copy.
///
/// Engine error text is intentionally accepted only as a signal that an
/// operation failed. It is never returned to presentation code because the
/// engine contract is English-only and may contain diagnostic details.
String? localizeStateProblem(
  AppLocalizations l10n, {
  UserProblem? problem,
  String diagnosticError = '',
}) {
  if (problem != null) return localizeProblem(l10n, problem);
  if (diagnosticError.trim().isNotEmpty) return l10n.problemOperationFailed;
  return null;
}
