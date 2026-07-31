import '../../app/app_controller.dart';
import 'connection_readiness.dart';
import 'connection_summary.dart';

extension AppStateConnection on AppState {
  ConnectionReadiness get connectionReadiness =>
      ConnectionReadiness.fromRuntime(
        transport: transport,
        peerServerStatus: peerServerStatus,
        startupSteps: startupSteps,
      );

  ConnectionSummary get connectionSummary => ConnectionSummary.fromReadiness(
    readiness: connectionReadiness,
    transport: transport,
  );
}
