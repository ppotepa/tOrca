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
    implements RuntimeCallBridge {
  const MobileBridge();

  static const _channel = MethodChannel('org.torchat/mobile');
  static const _eventsChannel = EventChannel('org.torchat/mobile/events');

  @override
  Stream<RuntimeEvent> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((value) => RuntimePayload.fromDynamic(value).runtimeEvent());

  /// Android owns relay retries in the foreground service. The Flutter startup
  /// barrier is local engine readiness, not remote relay availability. Start
  /// the long-running connect request once, then wait on a local query whose
  /// native implementation is guarded by `localReady`.
  @override
  Future<bool> connect() async {
    unawaited(
      _channel
          .invokeMethod<Object?>(EngineContract.connect)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    await _channel.invokeMethod<Object?>(EngineContract.getIdentity);
    return true;
  }

  @override
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) => _channel.invokeMethod(method, params.toMap());
}
