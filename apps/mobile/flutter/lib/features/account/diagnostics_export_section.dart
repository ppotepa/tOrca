import 'package:flutter/material.dart';
import 'package:torchat_flutter_ui/async/async_operation_state.dart';
import 'package:torchat_flutter_ui/async/busy_surface.dart';

import '../../platform/platform_services.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

class DiagnosticsExportSection extends StatefulWidget {
  const DiagnosticsExportSection({super.key});

  @override
  State<DiagnosticsExportSection> createState() =>
      _DiagnosticsExportSectionState();
}

class _DiagnosticsExportSectionState extends State<DiagnosticsExportSection> {
  bool _exporting = false;

  Future<void> _export() async {
    if (_exporting) return;
    final polish = Localizations.localeOf(context).languageCode == 'pl';
    setState(() => _exporting = true);
    try {
      final result = await PlatformServices.current.diagnostics.export();
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            polish
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
            polish
                ? 'Nie udało się wyeksportować diagnostyki.'
                : 'Unable to export diagnostics.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final polish = Localizations.localeOf(context).languageCode == 'pl';
    final operation = AsyncOperationState(
      phase: _exporting
          ? AsyncOperationPhase.running
          : AsyncOperationPhase.idle,
      label: polish ? 'Eksportowanie diagnostyki' : 'Exporting diagnostics',
    );
    return ActionSection(
      title: polish ? 'DIAGNOSTYKA' : 'DIAGNOSTICS',
      child: BusySurface(
        state: operation,
        label: operation.label,
        child: ActionTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: polish ? 'Eksportuj diagnostykę' : 'Export diagnostics',
          subtitle: polish
              ? 'Tworzy lokalny, skompresowany plik bez wiadomości, załączników i kluczy.'
              : 'Creates a local compressed file without messages, attachments or keys.',
          onTap: _exporting ? null : _export,
        ),
      ),
    );
  }
}
