import 'dart:async';

import 'application_snapshot.dart';
import 'application_snapshot_patch.dart';

class ApplicationStateStore {
  ApplicationStateStore();

  static final ApplicationStateStore shared = ApplicationStateStore();

  final StreamController<ApplicationSnapshot?> _changes =
      StreamController<ApplicationSnapshot?>.broadcast(sync: true);

  ApplicationSnapshot? _current;
  bool _stale = false;

  ApplicationSnapshot? get current => _current;

  bool get hasSnapshot => _current != null;

  bool get isStale => _stale;

  Stream<ApplicationSnapshot?> get changes => _changes.stream;

  bool hydrate(ApplicationSnapshot snapshot) {
    final current = _current;
    if (current != null && snapshot.generation < current.generation) {
      return false;
    }
    _current = snapshot;
    _stale = false;
    _changes.add(snapshot);
    return true;
  }

  bool applyPatch(ApplicationSnapshotPatch patch) {
    final current = _current;
    if (current == null || !patch.canApplyTo(current)) return false;
    _current = patch.applyTo(current);
    _stale = false;
    _changes.add(_current);
    return true;
  }

  void markStale() {
    if (_current == null || _stale) return;
    _stale = true;
  }

  void clear() {
    _current = null;
    _stale = false;
    _changes.add(null);
  }
}
