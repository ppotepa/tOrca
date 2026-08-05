import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/release/release_info.dart';
import '../../platform/platform_services.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

class ReleaseInformationSection extends StatefulWidget {
  const ReleaseInformationSection({
    super.key,
    required this.onResetUnavailable,
  });

  final VoidCallback onResetUnavailable;

  @override
  State<ReleaseInformationSection> createState() =>
      _ReleaseInformationSectionState();
}

class _ReleaseInformationSectionState
    extends State<ReleaseInformationSection> {
  bool _exportingDiagnostics = false;
  bool _resettingProfile = false;

  bool get _polish => Localizations.localeOf(context).languageCode == 'pl';

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: TorcaReleaseInfo.diagnosticLabel),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _polish
              ? 'Skopiowano informacje o wersji.'
              : 'Release information copied.',
        ),
      ),
    );
  }

  Future<void> _exportDiagnostics() async {
    if (_exportingDiagnostics) return;
    setState(() => _exportingDiagnostics = true);
    try {
      final result = await PlatformServices.current.diagnostics.export();
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _polish
                ? 'Zapisano zredagowaną diagnostykę: ${result.path}'
                : 'Sanitized diagnostics saved: ${result.path}',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _polish
                ? 'Nie udało się wyeksportować diagnostyki.'
                : 'Unable to export diagnostics.',
          ),
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _polish
                ? 'Profil został usunięty. Uruchom Torca ponownie.'
                : 'The profile was deleted. Restart Torca.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      widget.onResetUnavailable();
    } finally {
      if (mounted) setState(() => _resettingProfile = false);
    }
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
