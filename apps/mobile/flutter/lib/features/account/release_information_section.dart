import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notifications/ui_notification_center.dart';
import '../../core/release/release_info.dart';
import '../../platform/platform_services.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

class ReleaseInformationSection extends ConsumerStatefulWidget {
  const ReleaseInformationSection({
    super.key,
    required this.onResetUnavailable,
  });

  final VoidCallback onResetUnavailable;

  @override
  ConsumerState<ReleaseInformationSection> createState() =>
      _ReleaseInformationSectionState();
}

class _ReleaseInformationSectionState
    extends ConsumerState<ReleaseInformationSection> {
  bool _checkingUpdate = false;
  bool _exportingDiagnostics = false;
  bool _resettingProfile = false;

  bool get _polish => Localizations.localeOf(context).languageCode == 'pl';

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: TorcaReleaseInfo.diagnosticLabel),
    );
    if (!mounted) return;
    _showMessage(
      _polish
          ? 'Skopiowano informacje o wersji.'
          : 'Release information copied.',
    );
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final result = await PlatformServices.current.updates.selectAndVerifyManifest();
      if (!mounted || result == null) return;
      if (!result.updateAvailable) {
        _showMessage(
          _polish
              ? 'Ten build Torca jest aktualny względem wybranego manifestu.'
              : 'This Torca build is current for the selected manifest.',
        );
        return;
      }
      final artifact = result.artifact;
      if (artifact == null) {
        _showMessage(
          _polish
              ? 'Manifest jest poprawny, ale nie zawiera artefaktu dla tej platformy.'
              : 'The manifest is valid but has no artifact for this platform.',
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: artifact.url.toString()));
      if (!mounted) return;
      _showMessage(
        _polish
            ? 'Dostępna jest Torca ${result.manifest.version}+${result.manifest.build}. Zweryfikowany adres pobrania skopiowano do schowka.'
            : 'Torca ${result.manifest.version}+${result.manifest.build} is available. The verified download URL was copied.',
      );
    } catch (_) {
      if (!mounted) return;
      _showMessage(
        _polish
            ? 'Manifest aktualizacji jest niedostępny, uszkodzony albo ma nieprawidłowy podpis.'
            : 'The update manifest is unavailable, malformed or has an invalid signature.',
      );
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _exportDiagnostics() async {
    if (_exportingDiagnostics) return;
    setState(() => _exportingDiagnostics = true);
    try {
      final result = await PlatformServices.current.diagnostics.export();
      if (!mounted || result == null) return;
      _showMessage(
        _polish
            ? 'Zapisano zredagowaną diagnostykę: ${result.path}'
            : 'Sanitized diagnostics saved: ${result.path}',
      );
    } catch (_) {
      if (!mounted) return;
      _showMessage(
        _polish
            ? 'Nie udało się wyeksportować diagnostyki.'
            : 'Unable to export diagnostics.',
      );
    } finally {
      if (mounted) setState(() => _exportingDiagnostics = false);
    }
  }

  Future<void> _resetProfile() async {
    if (_resettingProfile) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          _polish ? 'Usunąć profil Torca?' : 'Delete the Torca profile?',
        ),
        content: Text(
          _polish
              ? 'Operacja bezpowrotnie usunie tożsamość, kontakty, historię, kolejki, klucze, dane Tor i ustawienia z tego urządzenia.'
              : 'This permanently deletes the identity, contacts, history, queues, keys, Tor data and preferences from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_polish ? 'Anuluj' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_polish ? 'Kontynuuj' : 'Continue'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_polish ? 'Ostateczne potwierdzenie' : 'Final confirmation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _polish
                    ? 'Wpisz DELETE, aby trwale usunąć profil.'
                    : 'Type DELETE to permanently remove the profile.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(_polish ? 'Anuluj' : 'Cancel'),
            ),
            FilledButton(
              onPressed: controller.text.trim() == 'DELETE'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(_polish ? 'Usuń wszystko' : 'Delete everything'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (confirmed != true || !mounted) return;

    setState(() => _resettingProfile = true);
    try {
      await PlatformServices.current.profileReset.resetLocalProfile();
      if (!mounted) return;
      _showMessage(
        _polish
            ? 'Profil został usunięty. Uruchom Torca ponownie.'
            : 'The profile was deleted. Restart Torca.',
      );
    } catch (_) {
      if (!mounted) return;
      widget.onResetUnavailable();
    } finally {
      if (mounted) setState(() => _resettingProfile = false);
    }
  }

  void _showMessage(String message) {
    ref
        .read(uiNotificationCenterProvider.notifier)
        .showInfo(message, deduplicationKey: 'release-info:$message');
  }

  @override
  Widget build(BuildContext context) => ActionSection(
        title: _polish ? 'WERSJA TESTOWA I WSPARCIE' : 'TEST RELEASE AND SUPPORT',
        child: Column(
          children: [
            ActionTile(
              leading: const Icon(Icons.info_outline),
              title:
                  '${TorcaReleaseInfo.product} ${TorcaReleaseInfo.displayVersion}',
              subtitle: _polish
                  ? 'Kanał: ${TorcaReleaseInfo.channel} · commit ${TorcaReleaseInfo.shortCommit}'
                  : 'Channel: ${TorcaReleaseInfo.channel} · commit ${TorcaReleaseInfo.shortCommit}',
              onTap: _copy,
            ),
            const Divider(height: 1),
            ActionTile(
              leading: const Icon(Icons.system_update_alt_outlined),
              title: _polish
                  ? 'Sprawdź plik aktualizacji'
                  : 'Check update manifest',
              subtitle: _polish
                  ? 'Weryfikuje lokalny manifest i podpis Ed25519 bez połączenia sieciowego.'
                  : 'Verifies a local manifest and Ed25519 signature without a network connection.',
              busy: _checkingUpdate,
              busyLabel: _polish
                  ? 'Weryfikowanie aktualizacji…'
                  : 'Verifying update…',
              onTap: _checkUpdate,
            ),
            const Divider(height: 1),
            ActionTile(
              leading: const Icon(Icons.bug_report_outlined),
              title:
                  _polish ? 'Eksportuj diagnostykę' : 'Export diagnostics',
              subtitle: _polish
                  ? 'Lokalny, skompresowany plik bez wiadomości, załączników i kluczy.'
                  : 'Local compressed file without messages, attachments or keys.',
              busy: _exportingDiagnostics,
              busyLabel: _polish
                  ? 'Eksportowanie diagnostyki…'
                  : 'Exporting diagnostics…',
              onTap: _exportDiagnostics,
            ),
            const Divider(height: 1),
            ActionTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: _polish ? 'Usuń lokalny profil' : 'Delete local profile',
              subtitle: _polish
                  ? 'Usuwa wszystkie dane i klucze Torca z tego urządzenia.'
                  : 'Removes all Torca data and keys from this device.',
              busy: _resettingProfile,
              busyLabel: _polish ? 'Usuwanie profilu…' : 'Deleting profile…',
              onTap: _resetProfile,
            ),
          ],
        ),
      );
}
