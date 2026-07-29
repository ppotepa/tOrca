import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../shared/widgets/action_tile.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/callout_card.dart';
import '../../shared/widgets/info_tile.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.nickname,
    required this.torStatus,
    required this.themePreferences,
    required this.onThemeFamilyChanged,
    required this.onBrightnessChanged,
    required this.onOpenTor,
    required this.onEditProfile,
    required this.onReset,
  });
  final String nickname;
  final String torStatus;
  final TorChatThemePreferences themePreferences;
  final ValueChanged<TorChatThemeFamily> onThemeFamilyChanged;
  final ValueChanged<TorChatBrightnessMode> onBrightnessChanged;
  final VoidCallback onOpenTor, onEditProfile;
  final VoidCallback onReset;

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
                leading: const Icon(Icons.palette_outlined),
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
                selected: {themePreferences.family},
                onSelectionChanged: (selected) {
                  final family = selected.firstOrNull;
                  if (family != null) onThemeFamilyChanged(family);
                },
              ),
              const SizedBox(height: 12),
              InfoTile(
                leading: const Icon(Icons.brightness_auto_outlined),
                title: 'Tryb jasności',
                subtitle: switch (themePreferences.brightness) {
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
                selected: {themePreferences.brightness},
                onSelectionChanged: (selected) {
                  final mode = selected.firstOrNull;
                  if (mode != null) onBrightnessChanged(mode);
                },
              ),
            ],
          ),
        ),
        ActionTile(
          leading: const Icon(Icons.eco_outlined),
          title: 'Połączenie Tor',
          subtitle: torStatus,
          onTap: onOpenTor,
        ),
        const Divider(),
        ActionSection(
          title: 'TOŻSAMOŚĆ',
          child: ActionTile(
            leading: const Icon(Icons.person_outline),
            title: 'Profil użytkownika',
            subtitle: '@$nickname',
            onTap: onEditProfile,
          ),
        ),
        const Divider(),
        ActionSection(
          title: 'DANE LOKALNE',
          child: CalloutCard(
            leading: Icon(
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
              onTap: onReset,
            ),
          ),
        ),
      ],
    ),
  );
}
