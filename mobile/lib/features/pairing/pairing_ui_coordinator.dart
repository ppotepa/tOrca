import '../../core/models/domain.dart';

enum PairingUiPhase {
  idle,
  showingCode,
  awaitingLocalDecision,
  processing,
  completed,
  failed,
}

/// Owns pairing surface coordination across the code dialog and the global
/// incoming-request prompt. The protocol state remains in the runtime; this
/// object only prevents duplicate UI surfaces and lost decisions.
class PairingUiCoordinator {
  PairingUiPhase phase = PairingUiPhase.idle;
  final Set<String> _scheduled = <String>{};
  final Set<String> _resolved = <String>{};

  bool get codeSurfaceOpen => phase == PairingUiPhase.showingCode;
  bool get incomingSurfaceOpen =>
      phase == PairingUiPhase.awaitingLocalDecision ||
      phase == PairingUiPhase.processing;

  bool canSchedule(PairingItem item) =>
      item.requiresLocalDecision &&
      !_resolved.contains(item.id) &&
      !_scheduled.contains(item.id) &&
      !codeSurfaceOpen &&
      !incomingSurfaceOpen;

  bool isResolved(String id) => _resolved.contains(id);

  void beginCodeSurface() {
    phase = PairingUiPhase.showingCode;
  }

  void endCodeSurface() {
    if (phase == PairingUiPhase.showingCode) phase = PairingUiPhase.idle;
  }

  bool schedule(String id) => _scheduled.add(id);

  void unschedule(String id) => _scheduled.remove(id);

  void beginIncoming(String id) {
    _scheduled.remove(id);
    phase = PairingUiPhase.awaitingLocalDecision;
  }

  void beginProcessing() {
    phase = PairingUiPhase.processing;
  }

  void resolve(String id) {
    _scheduled.remove(id);
    _resolved.add(id);
    phase = PairingUiPhase.completed;
  }

  void closeSurface() {
    if (phase != PairingUiPhase.showingCode) phase = PairingUiPhase.idle;
  }
}
