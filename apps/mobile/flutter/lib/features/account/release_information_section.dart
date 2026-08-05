import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/action_tile.dart';

abstract final class TorcaReleaseInfo {
  static const product = 'Torca';
  static const version = String.fromEnvironment(
    'TORCA_VERSION',
    defaultValue: 'development',
  );
  static const build = String.fromEnvironment(
    'TORCA_BUILD',
    defaultValue: 'local',
  );
  static const channel = String.fromEnvironment(
    'TORCA_CHANNEL',
    defaultValue: 'development',
  );
  static const commit = String.fromEnvironment(
    'TORCA_COMMIT',
    defaultValue: 'unknown',
  );

  static String get shortCommit =>
      commit.length <= 12 ? commit : commit.substring(0, 12);

  static String get displayVersion => '$version+$build';

  static String get diagnosticLabel =>
      '$product $displayVersion\nChannel: $channel\nCommit: $commit';
}

class ReleaseInformationSection extends StatelessWidget {
  const ReleaseInformationSection({super.key});

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
        trailing: IconButton(
          tooltip: polish
              ? 'Kopiuj informacje o wersji'
              : 'Copy release information',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () async {
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
          },
        ),
      ),
    );
  }
}
