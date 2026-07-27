import 'dart:async';

import 'package:flutter/services.dart';

import 'client_runtime.dart';

/// Flutter boundary for the Android Tor/MLS runtime.
/// The platform side owns the Tor process, identity and encrypted state.
class MobileBridge implements ClientRuntime {
  const MobileBridge();

  static const _channel = MethodChannel('org.torchat/mobile');
  static const _eventsChannel = EventChannel('org.torchat/mobile/events');

  @override
  Stream<Map<String, dynamic>> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  @override Future<bool> connect() async =>
      await _channel.invokeMethod<bool>('connect') ?? false;

  @override Future<Map<String, dynamic>?> identity() async =>
      _asMap(await _channel.invokeMethod('identity'));

  @override Future<Map<String, dynamic>?> refreshPairingCode() async =>
      _asMap(await _channel.invokeMethod('refreshPairingCode'));

  @override Future<Map<String, dynamic>> setNickname(String nickname) async =>
      _asMap(
        await _channel.invokeMethod('setNickname', {'nickname': nickname}),
      ) ??
      {};

  @override Future<void> submitPairingCode(String code) =>
      _channel.invokeMethod('submitPairingCode', {'code': code});

  @override Future<List<Map<String, dynamic>>> pairingInbox() async =>
      _asList(await _channel.invokeMethod('pairingInbox'));

  @override Future<void> acceptPairing(String pairingId) =>
      _channel.invokeMethod('acceptPairing', {'pairingId': pairingId});

  @override Future<void> rejectPairing(String pairingId) =>
      _channel.invokeMethod('rejectPairing', {'pairingId': pairingId});

  @override Future<void> verifyContact(String installationId) =>
      _channel.invokeMethod('verifyContact', {'installationId': installationId});

  @override Future<List<Map<String, dynamic>>> contacts() async =>
      _asList(await _channel.invokeMethod('contacts'));

  @override Future<List<Map<String, dynamic>>> conversations() async =>
      _asList(await _channel.invokeMethod('conversations'));

  @override Future<List<Map<String, dynamic>>> messages(String id) async =>
      _asList(await _channel.invokeMethod('messages', {'id': id}));

  @override Future<void> openConversation(String id) =>
      _channel.invokeMethod('openConversation', {'id': id});


  @override Future<void> sendMessage(String id, String text) =>
      _channel.invokeMethod('sendMessage', {'id': id, 'text': text});

  static Map<String, dynamic>? _asMap(dynamic value) =>
      value == null ? null : Map<String, dynamic>.from(value as Map);

  static List<Map<String, dynamic>> _asList(dynamic value) =>
      (value as List? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
}
