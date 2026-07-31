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

  @override
  Stream<RuntimeEvent> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((value) => RuntimePayload.fromDynamic(value).runtimeEvent());

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    try {
      final values = await Future.wait<Object?>([
        _channel.invokeMethod<Object?>(EngineContract.getIdentity),
        _channel.invokeMethod<Object?>(EngineContract.getProfile),
        _channel.invokeMethod<Object?>(EngineContract.listContacts),
        _channel.invokeMethod<Object?>(EngineContract.listConversations),
      ]);
      final identity = values[0];
      final profile = values[1];
      if (identity is! Map || profile is! Map) return null;

      var peerEndpointAvailable = false;
      try {
        peerEndpointAvailable =
            await _channel.invokeMethod<Object?>(EngineContract.getPeerEndpoint) !=
            null;
      } on PlatformException {
        // A missing endpoint is a normal warmup state, not attach failure.
      }

      final now = DateTime.now();
      return <String, dynamic>{
        'serviceAlive': true,
        'localDataReady': true,
        'generation': now.microsecondsSinceEpoch,
        'createdAtMs': now.millisecondsSinceEpoch,
        'identity': Map<String, dynamic>.from(identity),
        'profile': Map<String, dynamic>.from(profile),
        'contacts': _mapItems(values[2]),
        'conversations': _mapItems(values[3]),
        'peerEndpointAvailable': peerEndpointAvailable,
      };
    } on PlatformException {
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

List<Map<String, dynamic>> _mapItems(Object? value) {
  final items = value is Map ? value[EngineContract.items] : value;
  return (items as List? ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
