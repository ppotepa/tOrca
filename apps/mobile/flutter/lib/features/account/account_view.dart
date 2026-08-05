import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import '../../app/app_controller.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/connection/connection_readiness.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';
import '../../shared/widgets/identity_section.dart';
import '../../locales/presentation/app_localizations_x.dart';

class AccountView extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final canPair = ref.watch(
      appControllerProvider.select(
        (state) =>
            state.connectionReadiness.canPerform(ConnectionOperation.pair),
      ),
    );
    final inviteLoad = ref.watch(
      uiOperationProvider(UiOperationKey.inviteCodeLoad),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          IdentitySection(
            title: l10n.accountIdentitySection,
            name: nickname,
            subtitle: installationId.isEmpty
                ? l10n.accountLocalProfile
                : l10n.accountInstallationId(installationId),
            fingerprint: fingerprint,
            selectableFingerprint: true,
          ),
          const SizedBox(height: 12),
          ActionSection(
            title: l10n.accountActionsSection,
            child: Column(
              children: [
                ActionTile(
                  leading: const ThemedIcon(Icons.qr_code_2),
                  title: l10n.accountInviteCode,
                  busy: inviteLoad.busy,
                  busyLabel: l10n.accountInviteLoading,
                  subtitle: l10n.accountInviteSubtitle,
                  onTap: canPair ? onShowInvite : null,
                ),
                ActionTile(
                  leading: const ThemedIcon(Icons.settings_outlined),
                  title: l10n.accountSettings,
                  subtitle: l10n.accountSettingsSubtitle,
                  onTap: onOpenSettings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
