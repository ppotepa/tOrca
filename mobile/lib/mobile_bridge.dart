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

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    try {
      final identity = await _channel.invokeMethod<Object?>(
        EngineContract.getIdentity,
      );
      final profile = await _channel.invokeMethod<Object?>(
        EngineContract.getProfile,
      );
      if (identity is! Map || profile is! Map) return null;
      return <String, dynamic>{
        'serviceAlive': true,
        'localDataReady': true,
        'identity': Map<String, dynamic>.from(identity),
        'profile': Map<String, dynamic>.from(profile),
      };
    } on PlatformException {
      // A cold service start is not an error. initialize() continues through
      // the normal local-engine warmup path.
      return null;
    }
  }

  /// Android owns the process and shared engine. Calling connect is idempotent:
  /// on UI reattach it observes the existing service instead of rebuilding it.
  @override
  Future<bool> connect() async {
    unawaited(
      _channel
          .invokeMethod<Object?>(EngineContract.connect)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
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
