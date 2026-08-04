import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/desktop_autostart.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../app/ui_operation_registry.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/language_picker.dart';
import '../../locales/presentation/status_localizer.dart';
import '../../locales/presentation/theme_localizer.dart';
import '../../shared/async/async_operation_state.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';
import '../../shared/widgets/callout_card.dart';
import '../../shared/widgets/info_tile.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';
import 'image_storage_settings_section.dart';

class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({
    super.key,
    required this.nickname,
    @Deprecated('Tor status is read from the typed controller state.')
    this.torStatus = '',
    required this.themePreferences,
    required this.onThemeFamilyChanged,
    required this.onBrightnessChanged,
    required this.onRetroPaletteChanged,
    required this.onOpenTor,
    required this.onEditProfile,
    required this.onReset,
  });

  final String nickname;
  @Deprecated('Tor status is read from the typed controller state.')
  final String torStatus;
  final TorChatThemePreferences themePreferences;
  final ValueChanged<TorChatThemeFamily> onThemeFamilyChanged;
  final ValueChanged<TorChatBrightnessMode> onBrightnessChanged;
  final ValueChanged<TorChatRetroPalette> onRetroPaletteChanged;
  final VoidCallback onOpenTor;
  final VoidCallback onEditProfile;
  final VoidCallback onReset;

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  static const _reducedMotionKey = 'torchat.accessibility.reducedMotion';
  static const _autostartOperationKey = 'torchat.desktop.autostart';

  late TorChatThemePreferences _themePreferences;
  final Set<String> _saving = <String>{};
  bool _notifications = true;
  bool _messageAlerts = true;
  bool _sound = true;
  bool _vibration = true;
  bool _preview = false;
  bool _pairingAlerts = true;
  bool _readReceipts = false;
  bool _typing = true;
  bool _presence = true;
  bool _lastSeen = true;
  bool _autostart = false;

  @override
  void initState() {
    super.initState();
    _themePreferences = widget.themePreferences;
    _loadPreferences();
  }

  @override
  void didUpdateWidget(covariant SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themePreferences != widget.themePreferences) {
      _themePreferences = widget.themePreferences;
    }
  }

  Future<void> _loadPreferences() async {
    final store = await SharedPreferences.getInstance();
    var autostart = false;
    if (Platform.isWindows) {
      try {
        autostart = await DesktopAutostart.isEnabled();
      } catch (_) {
        autostart = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _notifications = store.getBool('torchat.notifications.enabled') ?? true;
      _messageAlerts = store.getBool('torchat.notifications.messages') ?? true;
      _sound = store.getBool('torchat.notifications.sound') ?? true;
      _vibration = store.getBool('torchat.notifications.vibration') ?? true;
      _preview = store.getBool('torchat.notifications.preview') ?? false;
      _pairingAlerts = store.getBool('torchat.notifications.pairing') ?? true;
      _readReceipts = store.getBool('torchat.privacy.readReceipts') ?? false;
      _typing = store.getBool('torchat.privacy.typing') ?? true;
      _presence = store.getBool('torchat.privacy.presence') ?? true;
      _lastSeen = store.getBool('torchat.privacy.lastSeen') ?? true;
      _autostart = autostart;
    });
  }

  void _showSettingsError({required String deduplicationKey}) {
    ref.read(uiNotificationCenterProvider.notifier).showError(
          context.l10n.uiSettingsSaveFailed,
          deduplicationKey: deduplicationKey,
        );
  }

  Future<void> _set(
    String key,
    bool previous,
    bool value,
    ValueChanged<bool> assign,
  ) async {
    setState(() {
      assign(value);
      _saving.add(key);
    });
    try {
      final store = await SharedPreferences.getInstance();
      final saved = await store.setBool(key, value);
      if (!saved) throw const _SettingsPersistenceException();
    } catch (_) {
      if (!mounted) return;
      setState(() => assign(previous));
      _showSettingsError(deduplicationKey: 'setting:$key:save-failed');
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  Future<void> _setReducedMotion(bool value) async {
    final previous = _themePreferences.reducedMotion;
    setState(() {
      _themePreferences = _themePreferences.copyWith(reducedMotion: value);
      _saving.add(_reducedMotionKey);
    });
    try {
      await ref.read(themeControllerProvider.notifier).setReducedMotion(value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _themePreferences = _themePreferences.copyWith(reducedMotion: previous);
      });
      _showSettingsError(deduplicationKey: 'setting:reduced-motion:failed');
    } finally {
      if (mounted) setState(() => _saving.remove(_reducedMotionKey));
    }
  }

  Future<void> _setAutostart(bool value) async {
    final previous = _autostart;
    setState(() {
      _autostart = value;
      _saving.add(_autostartOperationKey);
    });
    try {
      await DesktopAutostart.setEnabled(value);
      final actual = await DesktopAutostart.isEnabled();
      if (actual != value) throw const _AutostartConfirmationException();
      if (mounted) setState(() => _autostart = actual);
    } on _AutostartConfirmationException {
      if (!mounted) return;
      setState(() => _autostart = previous);
      ref.read(uiNotificationCenterProvider.notifier).showError(
            context.l10n.uiWindowsAutostartNotConfirmed,
            deduplicationKey: 'setting:autostart:not-confirmed',
          );
    } catch (_) {
      if (!mounted) return;
      setState(() => _autostart = previous);
      _showSettingsError(deduplicationKey: 'setting:autostart:failed');
    } finally {
      if (mounted) setState(() => _saving.remove(_autostartOperationKey));
    }
  }

  AsyncOperationState _preferenceState(String key) => AsyncOperationState(
    phase: _saving.contains(key)
        ? AsyncOperationPhase.running
        : AsyncOperationPhase.idle,
    label: context.l10n.settingsSaving,
    targetId: key,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final torPhase = ref.watch(
      appControllerProvider.select((state) => state.connectionSummary.phase),
    );
    final nicknameSave = ref.watch(
      uiOperationProvider(UiOperationKey.nicknameSave),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ActionSection(
            title: l10n.settingsApplicationSection,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoTile(
                  leading: const ThemedIcon(Icons.palette_outlined),
                  title: l10n.settingsFamilyTitle,
                  subtitle: l10n.settingsFamilyDescription,
                ),
                const SizedBox(height: 8),
                SegmentedButton<TorChatThemeFamily>(
                  segments: [
                    ButtonSegment(
                      value: TorChatThemeFamily.current,
                      label: Text(l10n.settingsClassic),
                    ),
                    ButtonSegment(
                      value: TorChatThemeFamily.retro,
                      label: Text(l10n.settingsRetro),
                    ),
                  ],
                  selected: {_themePreferences.family},
                  onSelectionChanged: (selected) {
                    if (selected.isEmpty) return;
                    final family = selected.first;
                    setState(() {
                      _themePreferences = _themePreferences.copyWith(
                        family: family,
                      );
                    });
                    widget.onThemeFamilyChanged(family);
                  },
                ),
                if (_themePreferences.family == TorChatThemeFamily.retro) ...[
                  const SizedBox(height: 12),
                  InfoTile(
                    leading: const ThemedIcon(Icons.terminal_outlined),
                    title: l10n.settingsTerminalPalette,
                    subtitle: localizeRetroPalette(
                      l10n,
                      _themePreferences.retroPalette,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<TorChatRetroPalette>(
                      segments: [
                        for (final palette in TorChatRetroPalette.values)
                          ButtonSegment(
                            value: palette,
                            label: Text(localizeRetroPalette(l10n, palette)),
                          ),
                      ],
                      selected: {_themePreferences.retroPalette},
                      showSelectedIcon: false,
                      onSelectionChanged: (selected) {
                        if (selected.isEmpty) return;
                        final palette = selected.first;
                        setState(() {
                          _themePreferences = _themePreferences.copyWith(
                            retroPalette: palette,
                          );
                        });
                        widget.onRetroPaletteChanged(palette);
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                InfoTile(
                  leading: const ThemedIcon(Icons.language_outlined),
                  title: l10n.languageSettingsTitle,
                  subtitle: l10n.languageSettingsDescription,
                ),
                const SizedBox(height: 6),
                const LanguagePicker(),
                const SizedBox(height: 12),
                InfoTile(
                  leading: const ThemedIcon(Icons.brightness_auto_outlined),
                  title: l10n.settingsBrightness,
                  subtitle: switch (_themePreferences.brightness) {
                    TorChatBrightnessMode.system => l10n.settingsSystem,
                    TorChatBrightnessMode.light => l10n.settingsLight,
                    TorChatBrightnessMode.dark => l10n.settingsDark,
                  },
                ),
                const SizedBox(height: 6),
                SegmentedButton<TorChatBrightnessMode>(
                  segments: [
                    ButtonSegment(
                      value: TorChatBrightnessMode.system,
                      label: Text(l10n.settingsSystem),
                    ),
                    ButtonSegment(
                      value: TorChatBrightnessMode.light,
                      label: Text(l10n.settingsLight),
                    ),
                    ButtonSegment(
                      value: TorChatBrightnessMode.dark,
                      label: Text(l10n.settingsDark),
                    ),
                  ],
                  selected: {_themePreferences.brightness},
                  onSelectionChanged: (selected) {
                    if (selected.isEmpty) return;
                    final mode = selected.first;
                    setState(() {
                      _themePreferences = _themePreferences.copyWith(
                        brightness: mode,
                      );
                    });
                    widget.onBrightnessChanged(mode);
                  },
                ),
                const SizedBox(height: 8),
                BusySurface(
                  state: _preferenceState(_reducedMotionKey),
                  label: l10n.settingsSaving,
                  child: ThemedSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.settingsReduceMotion),
                    subtitle: Text(l10n.settingsReduceMotionDescription),
                    value: _themePreferences.reducedMotion,
                    onChanged: _saving.contains(_reducedMotionKey)
                        ? null
                        : _setReducedMotion,
                  ),
                ),
                if (Platform.isWindows)
                  BusySurface(
                    state: _preferenceState(_autostartOperationKey),
                    label: l10n.settingsSaving,
                    child: ThemedSwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.settingsWindowsAutostart),
                      subtitle: Text(l10n.settingsWindowsAutostartDescription),
                      value: _autostart,
                      onChanged: _saving.contains(_autostartOperationKey)
                          ? null
                          : _setAutostart,
                    ),
                  ),
              ],
            ),
          ),
          ActionSection(
            title: l10n.settingsNotificationsSection,
            child: Column(
              children: [
                _toggle(
                  l10n.settingsNotifications,
                  l10n.settingsNotificationsDescription,
                  _notifications,
                  'torchat.notifications.enabled',
                  (value) => _notifications = value,
                ),
                _toggle(
                  l10n.settingsNewMessages,
                  l10n.settingsNewMessagesDescription,
                  _messageAlerts,
                  'torchat.notifications.messages',
                  (value) => _messageAlerts = value,
                  enabled: _notifications,
                ),
                _toggle(
                  l10n.settingsContactInvitations,
                  l10n.settingsContactInvitationsDescription,
                  _pairingAlerts,
                  'torchat.notifications.pairing',
                  (value) => _pairingAlerts = value,
                  enabled: _notifications,
                ),
                _toggle(
                  l10n.settingsNotificationSound,
                  l10n.settingsNotificationSoundDescription,
                  _sound,
                  'torchat.notifications.sound',
                  (value) => _sound = value,
                  enabled: _notifications,
                ),
                _toggle(
                  l10n.settingsNotificationVibration,
                  l10n.settingsNotificationVibrationDescription,
                  _vibration,
                  'torchat.notifications.vibration',
                  (value) => _vibration = value,
                  enabled: _notifications,
                ),
                _toggle(
                  l10n.settingsMessagePreview,
                  l10n.settingsMessagePreviewDescription,
                  _preview,
                  'torchat.notifications.preview',
                  (value) => _preview = value,
                  enabled: _notifications && _messageAlerts,
                ),
              ],
            ),
          ),
          const Divider(),
          ActionSection(
            title: l10n.settingsChatPrivacySection,
            child: Column(
              children: [
                _toggle(
                  l10n.settingsReadReceipts,
                  l10n.settingsReadReceiptsDescription,
                  _readReceipts,
                  'torchat.privacy.readReceipts',
                  (value) => _readReceipts = value,
                ),
                _toggle(
                  l10n.settingsTypingIndicator,
                  l10n.settingsTypingIndicatorDescription,
                  _typing,
                  'torchat.privacy.typing',
                  (value) => _typing = value,
                ),
                _toggle(
                  l10n.settingsOnlineStatus,
                  l10n.settingsOnlineStatusDescription,
                  _presence,
                  'torchat.privacy.presence',
                  (value) => _presence = value,
                ),
                _toggle(
                  l10n.settingsLastSeen,
                  l10n.settingsLastSeenDescription,
                  _lastSeen,
                  'torchat.privacy.lastSeen',
                  (value) => _lastSeen = value,
                  enabled: _presence,
                ),
              ],
            ),
          ),
          ActionTile(
            leading: const ThemedIcon(Icons.eco_outlined),
            title: l10n.settingsTorConnection,
            subtitle: localizeTransportPhase(l10n, torPhase),
            onTap: widget.onOpenTor,
          ),
          const Divider(),
          const ImageStorageSettingsSection(),
          const Divider(),
          ActionSection(
            title: l10n.settingsIdentitySection,
            child: ActionTile(
              leading: const ThemedIcon(Icons.person_outline),
              title: l10n.settingsUserProfile,
              busy: nicknameSave.busy,
              busyLabel: l10n.settingsSavingProfile,
              subtitle: '@${widget.nickname}',
              onTap: widget.onEditProfile,
            ),
          ),
          const Divider(),
          ActionSection(
            title: l10n.settingsLocalDataSection,
            child: CalloutCard(
              leading: ThemedIcon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: l10n.settingsResetDemoData,
              subtitle: l10n.settingsRequiresConfirmation,
              borderColor: Theme.of(
                context,
              ).colorScheme.error.withValues(alpha: .60),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              child: ActionTile(
                title: l10n.settingsClearLocalState,
                subtitle: l10n.settingsClearLocalStateDescription,
                onTap: widget.onReset,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    String key,
    ValueChanged<bool> assign, {
    bool enabled = true,
  }) => BusySurface(
    state: _preferenceState(key),
    label: context.l10n.settingsSaving,
    child: ThemedSwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: enabled && !_saving.contains(key)
          ? (next) => _set(key, value, next, assign)
          : null,
    ),
  );
}

final class _SettingsPersistenceException implements Exception {
  const _SettingsPersistenceException();
}

final class _AutostartConfirmationException implements Exception {
  const _AutostartConfirmationException();
}
