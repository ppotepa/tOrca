import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../shared/widgets/action_tile.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/identity_section.dart';

class AccountView extends StatelessWidget {
  const AccountView({
    super.key,
    required this.nickname,
    required this.installationId,
    required this.fingerprint,
    required this.onShowInvite,
    required this.onOpenSettings,
  });
  final String nickname;
  final String installationId;
  final String fingerprint;
  final VoidCallback onShowInvite;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Konto')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        IdentitySection(
          title: 'TOŻSAMOŚĆ',
          name: nickname,
          subtitle: installationId.isEmpty
              ? 'Lokalny profil urządzenia'
              : 'ID instalacji: $installationId',
          fingerprint: fingerprint,
          selectableFingerprint: true,
        ),
        const SizedBox(height: 12),
        ActionSection(
          title: 'AKCJE',
          child: Column(
            children: [
              ActionTile(
                leading: const ThemedIcon(Icons.qr_code_2),
                title: 'Mój kod zaproszenia',
                subtitle: 'Kod jest widoczny tylko w osobnym oknie',
                onTap: onShowInvite,
              ),
              ActionTile(
                leading: const ThemedIcon(Icons.settings_outlined),
                title: 'Ustawienia',
                subtitle: 'Otwórz ustawienia aplikacji',
                onTap: onOpenSettings,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
