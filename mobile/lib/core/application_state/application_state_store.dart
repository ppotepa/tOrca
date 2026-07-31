import 'application_snapshot.dart';

class ApplicationStateStore {
  ApplicationSnapshot? _current;

  ApplicationSnapshot? get current => _current;

  bool get hasSnapshot => _current != null;

  void hydrate(ApplicationSnapshot snapshot) {
    final current = _current;
    if (current != null && snapshot.generation < current.generation) return;
    _current = snapshot;
  }

  void clear() {
    _current = null;
  }
}
