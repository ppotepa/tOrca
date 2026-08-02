import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _storageKey = 'torchat.conversation.preferences.v1';

class ConversationPreference {
  const ConversationPreference({
    this.localTitle,
    this.pinned = false,
    this.muted = false,
    this.archived = false,
  });

  final String? localTitle;
  final bool pinned;
  final bool muted;
  final bool archived;

  ConversationPreference copyWith({
    String? localTitle,
    bool clearLocalTitle = false,
    bool? pinned,
    bool? muted,
    bool? archived,
  }) => ConversationPreference(
    localTitle: clearLocalTitle ? null : localTitle ?? this.localTitle,
    pinned: pinned ?? this.pinned,
    muted: muted ?? this.muted,
    archived: archived ?? this.archived,
  );

  Map<String, dynamic> toJson() => {
    if (localTitle != null) 'localTitle': localTitle,
    'pinned': pinned,
    'muted': muted,
    'archived': archived,
  };

  factory ConversationPreference.fromJson(Map<String, dynamic> json) =>
      ConversationPreference(
        localTitle: json['localTitle']?.toString().trim().isEmpty == false
            ? json['localTitle'].toString().trim()
            : null,
        pinned: json['pinned'] == true,
        muted: json['muted'] == true,
        archived: json['archived'] == true,
      );
}

final conversationPreferencesProvider =
    NotifierProvider<
      ConversationPreferencesController,
      Map<String, ConversationPreference>
    >(ConversationPreferencesController.new);

class ConversationPreferencesController
    extends Notifier<Map<String, ConversationPreference>> {
  bool _loaded = false;

  @override
  Map<String, ConversationPreference> build() {
    if (!_loaded) {
      _loaded = true;
      unawaited(_load());
    }
    return const {};
  }

  ConversationPreference forConversation(String conversationId) =>
      state[conversationId] ?? const ConversationPreference();

  Future<void> setTitle(String conversationId, String? title) async {
    final normalized = title?.trim();
    if (normalized != null && normalized.runes.length > 48) {
      throw ArgumentError.value(
        title,
        'title',
        'Maximum length is 48 characters',
      );
    }
    _put(
      conversationId,
      forConversation(conversationId).copyWith(
        localTitle: normalized,
        clearLocalTitle: normalized == null || normalized.isEmpty,
      ),
    );
    await _persist();
  }

  Future<void> togglePinned(String conversationId) async {
    final current = forConversation(conversationId);
    _put(conversationId, current.copyWith(pinned: !current.pinned));
    await _persist();
  }

  Future<void> toggleMuted(String conversationId) async {
    final current = forConversation(conversationId);
    _put(conversationId, current.copyWith(muted: !current.muted));
    await _persist();
  }

  Future<void> setArchived(String conversationId, bool archived) async {
    final current = forConversation(conversationId);
    _put(conversationId, current.copyWith(archived: archived));
    await _persist();
  }

  Future<void> remove(String conversationId) async {
    state = Map.unmodifiable({...state}..remove(conversationId));
    await _persist();
  }

  void _put(String conversationId, ConversationPreference value) {
    state = Map.unmodifiable({...state, conversationId: value});
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final loaded = <String, ConversationPreference>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        loaded[entry.key as String] = ConversationPreference.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
      state = Map.unmodifiable(loaded);
    } catch (_) {
      // Invalid local UI preferences must never block the application.
    }
  }

  Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      for (final entry in state.entries) entry.key: entry.value.toJson(),
    };
    await preferences.setString(_storageKey, jsonEncode(payload));
  }
}
