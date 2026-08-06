import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_runtime.dart';
import '../../core/platform/platform_ports.dart';
import '../diagnostics_export_service.dart';
import '../platform_services.dart' show PlatformServices;
import '../profile_reset_service.dart';
import '../update_check_service.dart';

final platformServicesProvider = Provider<PlatformServices>(
  (ref) => throw StateError('PlatformServices must be provided by TorcaApp'),
);

final windowLifecycleProvider = Provider<WindowLifecycleService>(
  (ref) => ref.watch(platformServicesProvider).windowLifecycle,
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => ref.watch(platformServicesProvider).notifications,
);

final navigationIntentProvider = Provider<NavigationIntentService>(
  (ref) => ref.watch(platformServicesProvider).navigation,
);

final autostartServiceProvider = Provider<AutostartService>(
  (ref) => ref.watch(platformServicesProvider).autostart,
);

final diagnosticsServiceProvider = Provider<DiagnosticsExportService>(
  (ref) => ref.watch(platformServicesProvider).diagnostics,
);

final profileResetProvider = Provider<ProfileResetService>(
  (ref) => ref.watch(platformServicesProvider).profileReset,
);

final updateCheckProvider = Provider<UpdateCheckService>(
  (ref) => ref.watch(platformServicesProvider).updates,
);

final runtimeBridgeFactoryProvider = Provider<RuntimeBridgeFactory>(
  (ref) => ref.watch(platformServicesProvider).runtimeBridgeFactory,
);

final runtimeHostProvider = Provider<ClientRuntime>(
  (ref) => ref.watch(runtimeBridgeFactoryProvider)(),
);
