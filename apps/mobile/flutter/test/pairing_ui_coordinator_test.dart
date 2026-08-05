import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_mobile/features/pairing/pairing_ui_coordinator.dart';

PairingItem incoming(String id) => PairingItem(
  id: id,
  status: InviteState.pending,
  origin: PairingOrigin.inbox,
  availableActions: const [PairingAvailableAction.accept],
);

void main() {
  test('code surface blocks a competing incoming prompt', () {
    final coordinator = PairingUiCoordinator();
    coordinator.beginCodeSurface();

    expect(coordinator.codeSurfaceOpen, isTrue);
    expect(coordinator.canSchedule(incoming('pairing-1')), isFalse);

    coordinator.endCodeSurface();
    expect(coordinator.canSchedule(incoming('pairing-1')), isTrue);
  });

  test('request scheduling and resolution are idempotent', () {
    final coordinator = PairingUiCoordinator();
    final item = incoming('pairing-1');

    expect(coordinator.canSchedule(item), isTrue);
    expect(coordinator.schedule(item.id), isTrue);
    expect(coordinator.canSchedule(item), isFalse);
    expect(coordinator.schedule(item.id), isFalse);

    coordinator.beginIncoming(item.id);
    coordinator.resolve(item.id);
    expect(coordinator.isResolved(item.id), isTrue);
    expect(coordinator.canSchedule(item), isFalse);
    coordinator.closeSurface();
    expect(coordinator.phase, PairingUiPhase.idle);
  });
}
