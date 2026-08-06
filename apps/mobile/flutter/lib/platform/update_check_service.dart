import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';

import '../core/release/release_info.dart';
import '../core/release/update_manifest.dart';

final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.manifest,
    required this.updateAvailable,
    required this.artifact,
  });

  final TorcaUpdateManifest manifest;
  final bool updateAvailable;
  final TorcaUpdateArtifact? artifact;
}

abstract interface class UpdateCheckService {
  Future<UpdateCheckResult?> selectAndVerifyManifest();
}

final class LocalSignedUpdateCheckService implements UpdateCheckService {
  const LocalSignedUpdateCheckService();

  @override
  Future<UpdateCheckResult?> selectAndVerifyManifest() async {
    if (!TorcaReleaseInfo.canVerifyUpdates) {
      throw StateError('This Torca build has no update verification key.');
    }
    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
      allowMultiple: false,
      withData: false,
      lockParentWindow: true,
    );
    if (selected == null || selected.files.isEmpty) return null;
    final path = selected.files.single.path;
    if (path == null || path.isEmpty) {
      throw StateError('The selected update manifest could not be read.');
    }

    final publicKeyBytes = Uint8List.fromList(
      base64Decode(TorcaReleaseInfo.updatePublicKey),
    );
    if (publicKeyBytes.length != 32) {
      throw const FormatException(
        'Torca update public key must contain 32 bytes.',
      );
    }
    final manifestBytes = await File(path).readAsBytes();
    if (manifestBytes.lengthInBytes > 1024 * 1024) {
      throw const FormatException('Torca update manifest exceeds 1 MiB.');
    }
    final manifest = await TorcaUpdateManifest.verifyAndParse(
      manifestBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      expectedKeyId: TorcaReleaseInfo.updateKeyId,
    );
    final currentBuild = TorcaReleaseInfo.numericBuild;
    if (currentBuild == null) {
      throw StateError('This Torca build has no numeric build identifier.');
    }
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isWindows
        ? 'windows'
        : Platform.operatingSystem;
    final architecture = Platform.isWindows ? 'x64' : null;
    return UpdateCheckResult(
      manifest: manifest,
      updateAvailable: manifest.isNewerThan(
        TorcaReleaseInfo.version,
        currentBuild,
      ),
      artifact: manifest.artifactFor(
        platform: platform,
        architecture: architecture,
      ),
    );
  }
}
