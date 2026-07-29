import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../shared/widgets/action_tile.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/callout_card.dart';
import '../../shared/widgets/info_tile.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.nickname,
    required this.torStatus,
    required this.themePreferences,
    required this.onThemeFamilyChanged,
    required this.onBrightnessChanged,
    required this.onRetroPaletteChanged,
    required this.onOpenTor,
    required this.onEditProfile,
    required this.onReset,
  });
  final String nickname;
  final String torStatus;
  final TorChatThemePreferences themePreferences;
  final ValueChanged<TorChatThemeFamily> onThemeFamilyChanged;
  final ValueChanged<TorChatBrightnessMode> onBrightnessChanged;
  final ValueChanged<TorChatRetroPalette> onRetroPaletteChanged;
  final VoidCallback onOpenTor, onEditProfile;
  final VoidCallback onReset;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late TorChatThemePreferences _themePreferences;
  bool _notifications = true;
  bool _sound = true;
  bool _vibration = true;
  bool _preview = false;
  bool _pairingAlerts = true;
  bool _readReceipts = false;
  bool _typing = true;
  bool _presence = true;

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
    if (!mounted) return;
    setState(() {
      _notifications = store.getBool('torchat.notifications.enabled') ?? true;
      _sound = store.getBool('torchat.notifications.sound') ?? true;
      _vibration = store.getBool('torchat.notifications.vibration') ?? true;
      _preview = store.getBool('torchat.notifications.preview') ?? false;
      _pairingAlerts = store.getBool('torchat.notifications.pairing') ?? true;
      _readReceipts = store.getBool('torchat.privacy.readReceipts') ?? false;
      _typing = store.getBool('torchat.privacy.typing') ?? true;
      _presence = store.getBool('torchat.privacy.presence') ?? true;
    });
  }

  Future<void> _set(String key, bool value) async {
    final store = await SharedPreferences.getInstance();
    await store.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ustawienia')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ActionSection(
          title: 'APLIKACJA',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoTile(
                leading: const ThemedIcon(Icons.palette_outlined),
                title: 'Family',
                subtitle: 'Classic: klasyczny, Retro: styl retro',
              ),
              const SizedBox(height: 8),
              SegmentedButton<TorChatThemeFamily>(
                segments: const [
                  ButtonSegment(
                    value: TorChatThemeFamily.current,
                    label: Text('Classic'),
                  ),
                  ButtonSegment(
                    value: TorChatThemeFamily.retro,
                    label: Text('Retro'),
                  ),
                ],
                selected: {_themePreferences.family},
                onSelectionChanged: (selected) {
                  final family = selected.firstOrNull;
                  if (family != null) {
                    setState(() {
                      _themePreferences = _themePreferences.copyWith(
                        family: family,
                      );
                    });
                    widget.onThemeFamilyChanged(family);
                  }
                },
              ),
              if (_themePreferences.family == TorChatThemeFamily.retro) ...[
                const SizedBox(height: 12),
                InfoTile(
                  leading: const ThemedIcon(Icons.terminal_outlined),
                  title: 'Paleta terminalowa',
                  subtitle: _themePreferences.retroPalette.label,
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<TorChatRetroPalette>(
                    segments: [
                      for (final palette in TorChatRetroPalette.values)
                        ButtonSegment(
                          value: palette,
                          label: Text(palette.label),
                        ),
                    ],
                    selected: {_themePreferences.retroPalette},
                    showSelectedIcon: false,
                    onSelectionChanged: (selected) {
                      final palette = selected.firstOrNull;
                      if (palette != null) {
                        setState(() {
                          _themePreferences = _themePreferences.copyWith(
                            retroPalette: palette,
                          );
                        });
                        widget.onRetroPaletteChanged(palette);
                      }
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              InfoTile(
                leading: const ThemedIcon(Icons.brightness_auto_outlined),
                title: 'Tryb jasności',
                subtitle: switch (_themePreferences.brightness) {
                  TorChatBrightnessMode.system => 'System',
                  TorChatBrightnessMode.light => 'Jasny',
                  TorChatBrightnessMode.dark => 'Ciemny',
                },
              ),
              const SizedBox(height: 6),
              SegmentedButton<TorChatBrightnessMode>(
                segments: const [
                  ButtonSegment(
                    value: TorChatBrightnessMode.system,
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: TorChatBrightnessMode.light,
                    label: Text('Jasny'),
                  ),
                  ButtonSegment(
                    value: TorChatBrightnessMode.dark,
                    label: Text('Ciemny'),
                  ),
                ],
                selected: {_themePreferences.brightness},
                onSelectionChanged: (selected) {
                  final mode = selected.firstOrNull;
                  if (mode != null) {
                    setState(() {
                      _themePreferences = _themePreferences.copyWith(
                        brightness: mode,
                      );
                    });
                    widget.onBrightnessChanged(mode);
                  }
                },
              ),
            ],
          ),
        ),
        ActionSection(
          title: 'POWIADOMIENIA',
          child: Column(
            children: [
              _toggle(
                'Powiadomienia',
                'Nowe wiadomości i zaproszenia',
                _notifications,
                'torchat.notifications.enabled',
                (value) => _notifications = value,
              ),
              _toggle(
                'Dźwięk',
                'Systemowy dźwięk powiadomienia TorChat',
                _sound,
                'torchat.notifications.sound',
                (value) => _sound = value,
                enabled: _notifications,
              ),
              _toggle(
                'Wibracja',
                'Wibracja dla zdarzeń przychodzących',
                _vibration,
                'torchat.notifications.vibration',
                (value) => _vibration = value,
                enabled: _notifications,
              ),
              _toggle(
                'Podgląd treści',
                'Wyłączone domyślnie dla prywatności',
                _preview,
                'torchat.notifications.preview',
                (value) => _preview = value,
                enabled: _notifications,
              ),
              _toggle(
                'Zaproszenia do kontaktów',
                'Powiadamiaj o nowych prośbach pairing',
                _pairingAlerts,
                'torchat.notifications.pairing',
                (value) => _pairingAlerts = value,
                enabled: _notifications,
              ),
            ],
          ),
        ),
        const Divider(),
        ActionSection(
          title: 'PRYWATNOŚĆ CZATU',
          child: Column(
            children: [
              _toggle(
                'Potwierdzenia odczytu',
                'Informuj kontakt, że wiadomość została odczytana',
                _readReceipts,
                'torchat.privacy.readReceipts',
                (value) => _readReceipts = value,
              ),
              _toggle(
                'Informacja „pisze…”',
                'Udostępnia chwilową aktywność podczas pisania',
                _typing,
                'torchat.privacy.typing',
                (value) => _typing = value,
              ),
              _toggle(
                'Status online',
                'Udostępnia tylko bieżącą obecność bez historii',
                _presence,
                'torchat.privacy.presence',
                (value) => _presence = value,
              ),
            ],
          ),
        ),
        ActionTile(
          leading: const ThemedIcon(Icons.eco_outlined),
          title: 'Połączenie Tor',
          subtitle: widget.torStatus,
          onTap: widget.onOpenTor,
        ),
        const Divider(),
        ActionSection(
          title: 'TOŻSAMOŚĆ',
          child: ActionTile(
            leading: const ThemedIcon(Icons.person_outline),
            title: 'Profil użytkownika',
            subtitle: '@${widget.nickname}',
            onTap: widget.onEditProfile,
          ),
        ),
        const Divider(),
        ActionSection(
          title: 'DANE LOKALNE',
          child: CalloutCard(
            leading: ThemedIcon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: 'Reset danych demo',
            subtitle: 'Wymaga potwierdzenia',
            borderColor: Theme.of(
              context,
            ).colorScheme.error.withValues(alpha: .60),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            child: ActionTile(
              title: 'Wyczyść lokalny stan',
              subtitle: 'Usuwa wszystkie dane testowe i lokalne wpisy',
              onTap: widget.onReset,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    String key,
    ValueChanged<bool> assign, {
    bool enabled = true,
  }) => ThemedSwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: enabled
        ? (next) {
            setState(() => assign(next));
            _set(key, next);
          }
        : null,
  );
}
