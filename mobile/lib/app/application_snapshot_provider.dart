import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_state/application_snapshot.dart';
import 'app_controller.dart';

final applicationSnapshotProvider = StreamProvider<ApplicationSnapshot?>((ref) async* {
  final repository = ref.watch(runtimeRepositoryProvider);
  yield repository.applicationState.current;
  yield* repository.applicationSnapshots;
});
