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

  static Map<String, Object> get diagnosticMetadata => <String, Object>{
        'product': product,
        'version': version,
        'build': build,
        'channel': channel,
        'commit': commit,
      };

  static String get diagnosticLabel =>
      '$product $displayVersion\nChannel: $channel\nCommit: $commit';
}
