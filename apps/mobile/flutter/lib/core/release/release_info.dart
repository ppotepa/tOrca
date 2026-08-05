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
  static const updateKeyId = String.fromEnvironment(
    'TORCA_UPDATE_KEY_ID',
    defaultValue: '',
  );
  static const updatePublicKey = String.fromEnvironment(
    'TORCA_UPDATE_PUBLIC_KEY',
    defaultValue: '',
  );

  static String get shortCommit =>
      commit.length <= 12 ? commit : commit.substring(0, 12);

  static String get displayVersion => '$version+$build';

  static int? get numericBuild => int.tryParse(build);

  static bool get canVerifyUpdates =>
      updateKeyId.isNotEmpty && updatePublicKey.isNotEmpty;

  static Map<String, Object> get diagnosticMetadata => <String, Object>{
        'product': product,
        'version': version,
        'build': build,
        'channel': channel,
        'commit': commit,
        'updateKeyId': updateKeyId.isEmpty ? 'not-configured' : updateKeyId,
      };

  static String get diagnosticLabel =>
      '$product $displayVersion\nChannel: $channel\nCommit: $commit';
}
