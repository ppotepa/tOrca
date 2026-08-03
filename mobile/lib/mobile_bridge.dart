import 'dart:async';

import 'package:flutter/services.dart';

import 'client_runtime.dart';
import 'core/runtime/runtime_arguments.dart';
import 'core/runtime/runtime_bridge_base.dart';
import 'core/runtime/runtime_contract.dart';
import 'core/runtime/runtime_payload.dart';

/// Flutter boundary for the Android Tor/MLS runtime.
/// The platform side owns the Tor process, identity and encrypted state.
class MobileBridge extends Object
    with RuntimeBridgeMethods
    implements RuntimeCallBridge, RuntimeAttachmentProvider {
  const MobileBridge();

  static const _channel = MethodChannel('org.torchat/mobile');
  static const _eventsChannel = EventChannel('org.torchat/mobile/events');
  static const _reattachBudget = Duration(milliseconds: 750);

  @override
  Stream<RuntimeEvent> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((value) => RuntimePayload.fromDynamic(value).runtimeEvent());

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    try {
      // Reattach must consume the same atomic projection as the normal
      // repository refresh. The previous four independent calls could mix a
      // pre-pairing contact list with a post-pairing conversation list and
      // produced restart-only UI updates.
      final value = await _channel
          .invokeMethod<Object?>(EngineContract.getApplicationSnapshot)
          .timeout(_reattachBudget);
      if (value is! Map) return null;
      final snapshot = Map<String, dynamic>.from(value);
      snapshot['serviceAlive'] = true;
      snapshot['localDataReady'] = true;
      return snapshot;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Android owns the process and shared engine. Calling connect is idempotent:
  /// on UI reattach it observes the existing service instead of rebuilding it.
  @override
  Future<bool> connect() async {
    // Do not race the startup orchestrator with the Android service. The
    // connect response is the service's process/engine readiness barrier;
    // swallowing it made warmup continue while the engine was still starting.
    await _channel
        .invokeMethod<Object?>(EngineContract.connect)
        .timeout(const Duration(seconds: 45));
    await _channel.invokeMethod<Object?>(EngineContract.getIdentity);
    return true;
  }

  @override
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) => _channel.invokeMethod(method, params.toMap());
}
