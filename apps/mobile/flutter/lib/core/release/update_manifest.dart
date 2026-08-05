import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final class TorcaVersion implements Comparable<TorcaVersion> {
  const TorcaVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
  });

  factory TorcaVersion.parse(String value) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(value.trim());
    if (match == null) throw FormatException('Invalid Torca version: $value');
    return TorcaVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      preRelease: match.group(4),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  @override
  int compareTo(TorcaVersion other) {
    for (final comparison in <int>[
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }
    if (preRelease == null && other.preRelease == null) return 0;
    if (preRelease == null) return 1;
    if (other.preRelease == null) return -1;

    final left = preRelease!.split('.');
    final right = other.preRelease!.split('.');
    for (var index = 0; index < left.length || index < right.length; index++) {
      if (index >= left.length) return -1;
      if (index >= right.length) return 1;
      final leftNumber = int.tryParse(left[index]);
      final rightNumber = int.tryParse(right[index]);
      if (leftNumber != null && rightNumber != null) {
        final comparison = leftNumber.compareTo(rightNumber);
        if (comparison != 0) return comparison;
        continue;
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      final comparison = left[index].compareTo(right[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}

final class TorcaUpdateArtifact {
  const TorcaUpdateArtifact({
    required this.platform,
    required this.architecture,
    required this.kind,
    required this.fileName,
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  factory TorcaUpdateArtifact.fromJson(Map<String, Object?> json) {
    final url = Uri.parse(_requiredString(json, 'url'));
    if (!url.isAbsolute ||
        (url.scheme != 'https' &&
            !(url.scheme == 'http' && url.host.endsWith('.onion')))) {
      throw const FormatException('Update artifact URL is not trusted.');
    }
    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Update artifact SHA-256 is invalid.');
    }
    return TorcaUpdateArtifact(
      platform: _requiredString(json, 'platform'),
      architecture: _requiredString(json, 'architecture'),
      kind: _requiredString(json, 'kind'),
      fileName: _requiredString(json, 'fileName'),
      url: url,
      bytes: _requiredInt(json, 'bytes'),
      sha256: sha256,
    );
  }

  final String platform;
  final String architecture;
  final String kind;
  final String fileName;
  final Uri url;
  final int bytes;
  final String sha256;
}

final class TorcaUpdateManifest {
  const TorcaUpdateManifest({
    required this.version,
    required this.build,
    required this.channel,
    required this.commit,
    required this.publishedAtUtc,
    required this.minimumSupportedVersion,
    required this.mandatory,
    required this.releaseNotesUrl,
    required this.artifacts,
    required this.keyId,
  });

  static Future<TorcaUpdateManifest> verifyAndParse(
    Uint8List envelopeBytes, {
    required SimplePublicKey publicKey,
    required String expectedKeyId,
  }) async {
    final decoded = jsonDecode(utf8.decode(envelopeBytes));
    if (decoded is! Map) {
      throw const FormatException('Update manifest envelope must be an object.');
    }
    final envelope = decoded.cast<String, Object?>();
    if (_requiredInt(envelope, 'schema') != 1 ||
        _requiredString(envelope, 'algorithm') != 'ed25519') {
      throw const FormatException('Unsupported update manifest envelope.');
    }
    final keyId = _requiredString(envelope, 'keyId');
    if (keyId != expectedKeyId) {
      throw const FormatException('Update manifest signing key is unexpected.');
    }
    final payload = Uint8List.fromList(base64Decode(_requiredString(envelope, 'payload')));
    final signature = Signature(
      base64Decode(_requiredString(envelope, 'signature')),
      publicKey: publicKey,
    );
    final verified = await Ed25519().verify(payload, signature: signature);
    if (!verified) throw const FormatException('Update manifest signature is invalid.');

    final payloadValue = jsonDecode(utf8.decode(payload));
    if (payloadValue is! Map) {
      throw const FormatException('Update manifest payload must be an object.');
    }
    final json = payloadValue.cast<String, Object?>();
    if (_requiredInt(json, 'schema') != 1 ||
        _requiredString(json, 'product') != 'Torca') {
      throw const FormatException('Unsupported Torca update payload.');
    }
    final artifactsValue = json['artifacts'];
    if (artifactsValue is! List || artifactsValue.isEmpty) {
      throw const FormatException('Update manifest contains no artifacts.');
    }
    return TorcaUpdateManifest(
      version: TorcaVersion.parse(_requiredString(json, 'version')),
      build: _requiredInt(json, 'build'),
      channel: _requiredString(json, 'channel'),
      commit: _requiredString(json, 'commit'),
      publishedAtUtc: DateTime.parse(_requiredString(json, 'publishedAtUtc')).toUtc(),
      minimumSupportedVersion:
          TorcaVersion.parse(_requiredString(json, 'minimumSupportedVersion')),
      mandatory: json['mandatory'] == true,
      releaseNotesUrl: _optionalUri(json['releaseNotesUrl']),
      artifacts: artifactsValue
          .map((value) => TorcaUpdateArtifact.fromJson(
                (value as Map).cast<String, Object?>(),
              ))
          .toList(growable: false),
      keyId: keyId,
    );
  }

  final TorcaVersion version;
  final int build;
  final String channel;
  final String commit;
  final DateTime publishedAtUtc;
  final TorcaVersion minimumSupportedVersion;
  final bool mandatory;
  final Uri? releaseNotesUrl;
  final List<TorcaUpdateArtifact> artifacts;
  final String keyId;

  bool isNewerThan(String currentVersion, int currentBuild) {
    final comparison = version.compareTo(TorcaVersion.parse(currentVersion));
    return comparison > 0 || (comparison == 0 && build > currentBuild);
  }

  TorcaUpdateArtifact? artifactFor({
    required String platform,
    String? architecture,
  }) {
    for (final artifact in artifacts) {
      if (artifact.platform == platform &&
          (architecture == null ||
              artifact.architecture == architecture ||
              artifact.architecture == 'multi')) {
        return artifact;
      }
    }
    return null;
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Update manifest field $key must be a string.');
  }
  return value.trim();
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value >= 0) return value;
  throw FormatException('Update manifest field $key must be a non-negative integer.');
}

Uri? _optionalUri(Object? value) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Release notes URL is invalid.');
  }
  final uri = Uri.parse(value);
  if (!uri.isAbsolute || uri.scheme != 'https') {
    throw const FormatException('Release notes URL must use HTTPS.');
  }
  return uri;
}
