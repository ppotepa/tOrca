import 'dart:async';

import 'package:flutter/services.dart';

/// Flutter boundary for the Android Tor/MLS runtime.
/// The platform side owns the Tor process, identity and encrypted state.
class MobileBridge {
  const MobileBridge();

  static const _channel = MethodChannel('org.torchat/mobile');
  static const _eventsChannel = EventChannel('org.torchat/mobile/events');

  Stream<Map<String, dynamic>> get events => _eventsChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  Future<bool> connect() async =>
      await _channel.invokeMethod<bool>('connect') ?? false;

  Future<Map<String, dynamic>?> identity() async =>
      _asMap(await _channel.invokeMethod('identity'));

  Future<String?> refreshInvite() =>
      _channel.invokeMethod<String>('refreshInvite');

  Future<Map<String, dynamic>> setNickname(String nickname) async =>
      _asMap(
        await _channel.invokeMethod('setNickname', {'nickname': nickname}),
      ) ??
      {};

  Future<List<Map<String, dynamic>>> searchContacts(String query) async =>
      _asList(await _channel.invokeMethod('searchContacts', {'query': query}));

  Future<List<Map<String, dynamic>>> contacts() async =>
      _asList(await _channel.invokeMethod('contacts'));

  Future<List<Map<String, dynamic>>> conversations() async =>
      _asList(await _channel.invokeMethod('conversations'));

  Future<List<Map<String, dynamic>>> messages(String id) async =>
      _asList(await _channel.invokeMethod('messages', {'id': id}));

  Future<void> openConversation(String id) =>
      _channel.invokeMethod('openConversation', {'id': id});

  Future<void> startConversation(Map<String, dynamic> contact) =>
      _channel.invokeMethod('startConversation', {'contact': contact});

  Future<String?> startConversationFromInvite(String invite) => _channel
      .invokeMethod<String>('startConversationFromInvite', {'invite': invite});

  Future<void> sendMessage(String id, String text) =>
      _channel.invokeMethod('sendMessage', {'id': id, 'text': text});

  static Map<String, dynamic>? _asMap(dynamic value) =>
      value == null ? null : Map<String, dynamic>.from(value as Map);

  static List<Map<String, dynamic>> _asList(dynamic value) =>
      (value as List? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
}
