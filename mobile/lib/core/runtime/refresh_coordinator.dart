import 'dart:async';

/// Coalesces refresh requests raised by startup and event bursts.
///
/// A single generation runs at a time. Requests arriving during that generation
/// are marked dirty and trigger at most one follow-up run after a short debounce.
/// Remote pairing synchronization additionally observes a cooldown so repeated
/// relay events cannot hammer the server.
final class RefreshCoordinator {
  RefreshCoordinator({
    this.debounce = const Duration(milliseconds: 200),
    this.remoteCooldown = const Duration(seconds: 5),
  });

  final Duration debounce;
  final Duration remoteCooldown;

  Future<void>? _inFlight;
  bool _localDirty = false;
  bool _remoteDirty = false;
  int _generation = 0;
  DateTime? _lastRemoteRefresh;

  int get generation => _generation;
  bool get running => _inFlight != null;

  Future<void> schedule({
    required Future<void> Function(int generation) local,
    Future<void> Function(int generation)? remote,
    bool includeRemote = false,
  }) {
    _localDirty = true;
    _remoteDirty = _remoteDirty || includeRemote;
    final current = _inFlight;
    if (current != null) return current;

    final request = _drain(local: local, remote: remote);
    _inFlight = request;
    return request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    });
  }

  Future<void> _drain({
    required Future<void> Function(int generation) local,
    Future<void> Function(int generation)? remote,
  }) async {
    do {
      final runLocal = _localDirty;
      final runRemote = _remoteDirty;
      _localDirty = false;
      _remoteDirty = false;
      final generation = ++_generation;

      if (runLocal) await local(generation);
      if (runRemote && remote != null) {
        final last = _lastRemoteRefresh;
        if (last != null) {
          final remaining = remoteCooldown - DateTime.now().difference(last);
          if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        }
        await remote(generation);
        _lastRemoteRefresh = DateTime.now();
      }

      if (_localDirty || _remoteDirty) {
        await Future<void>.delayed(debounce);
      }
    } while (_localDirty || _remoteDirty);
  }
}
