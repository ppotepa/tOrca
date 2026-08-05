import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/release/release_info.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

class ReleaseInformationSection extends StatelessWidget {
  const ReleaseInformationSection({super.key});

  Future<void> _copy(BuildContext context) async {
    final polish = Localizations.localeOf(context).languageCode == 'pl';
    await Clipboard.setData(
      ClipboardData(text: TorcaReleaseInfo.diagnosticLabel),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          polish
              ? 'Skopiowano informacje o wersji.'
              : 'Release information copied.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final polish = Localizations.localeOf(context).languageCode == 'pl';
    return ActionSection(
      title: polish ? 'WERSJA TESTOWA' : 'TEST RELEASE',
      child: ActionTile(
        leading: const Icon(Icons.info_outline),
        title: '${TorcaReleaseInfo.product} ${TorcaReleaseInfo.displayVersion}',
        subtitle: polish
            ? 'Kanał: ${TorcaReleaseInfo.channel} · commit ${TorcaReleaseInfo.shortCommit}'
            : 'Channel: ${TorcaReleaseInfo.channel} · commit ${TorcaReleaseInfo.shortCommit}',
        onTap: () => _copy(context),
      ),
    );
  }
}
