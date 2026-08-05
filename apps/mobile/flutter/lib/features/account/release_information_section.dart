import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/release/release_info.dart';
import '../../platform/platform_services.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

class ReleaseInformationSection extends StatefulWidget {
  const ReleaseInformationSection({super.key});

  @override
  State<ReleaseInformationSection> createState() =>
      _ReleaseInformationSectionState();
}

class _ReleaseInformationSectionState
    extends State<ReleaseInformationSection> {
  bool _exportingDiagnostics = false;

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
          ],
        ),
      );
}
