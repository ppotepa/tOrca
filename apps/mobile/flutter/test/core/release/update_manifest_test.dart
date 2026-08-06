import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/release/update_manifest.dart';

void main() {
  test(
    'verifies a signed manifest and selects the platform artifact',
    () async {
      final fixture = await _signedFixture();

      final manifest = await TorcaUpdateManifest.verifyAndParse(
        fixture.envelope,
        publicKey: fixture.publicKey,
        expectedKeyId: 'torca-test-key',
      );

      expect(manifest.version.toString(), '0.2.0-beta.2');
      expect(manifest.isNewerThan('0.2.0-beta.1', 2), isTrue);
      expect(
        manifest.artifactFor(platform: 'android')?.fileName,
        'torca-0.2.0-beta.2-android.apk',
      );
    },
  );

  test('rejects payload tampering and a foreign key id', () async {
    final fixture = await _signedFixture();
    final envelope =
        jsonDecode(utf8.decode(fixture.envelope)) as Map<String, dynamic>;
    final payload = base64Decode(envelope['payload'] as String);
    payload[payload.length - 1] ^= 1;
    envelope['payload'] = base64Encode(payload);

    expect(
      TorcaUpdateManifest.verifyAndParse(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        publicKey: fixture.publicKey,
        expectedKeyId: 'torca-test-key',
      ),
      throwsFormatException,
    );
    expect(
      TorcaUpdateManifest.verifyAndParse(
        fixture.envelope,
        publicKey: fixture.publicKey,
        expectedKeyId: 'different-key',
      ),
      throwsFormatException,
    );
  });

  test('orders prerelease identifiers before release versions', () {
    expect(
      TorcaVersion.parse(
        '0.2.0-beta.2',
      ).compareTo(TorcaVersion.parse('0.2.0-rc.1')),
      lessThan(0),
    );
    expect(
      TorcaVersion.parse('0.2.0-rc.1').compareTo(TorcaVersion.parse('0.2.0')),
      lessThan(0),
    );
    expect(
      TorcaVersion.parse(
        '0.2.0-beta.10',
      ).compareTo(TorcaVersion.parse('0.2.0-beta.2')),
      greaterThan(0),
    );
  });
}

final class _SignedFixture {
  const _SignedFixture({required this.envelope, required this.publicKey});

  final Uint8List envelope;
  final SimplePublicKey publicKey;
}

Future<_SignedFixture> _signedFixture() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(
    List<int>.generate(32, (index) => index + 1),
  );
  final publicKey = await keyPair.extractPublicKey();
  final payload = utf8.encode(
    jsonEncode(<String, Object?>{
      'schema': 1,
      'product': 'Torca',
      'version': '0.2.0-beta.2',
      'build': 3,
      'channel': 'beta',
      'commit': '0123456789abcdef',
      'publishedAtUtc': '2026-08-05T12:00:00Z',
      'minimumSupportedVersion': '0.1.0',
      'mandatory': false,
      'releaseNotesUrl': 'https://example.invalid/torca/beta.2',
      'artifacts': <Map<String, Object>>[
        <String, Object>{
          'platform': 'android',
          'architecture': 'multi',
          'kind': 'apk',
          'fileName': 'torca-0.2.0-beta.2-android.apk',
          'url': 'https://example.invalid/torca-0.2.0-beta.2-android.apk',
          'bytes': 1024,
          'sha256': List<String>.filled(64, 'a').join(),
        },
      ],
    }),
  );
  final signature = await algorithm.sign(payload, keyPair: keyPair);
  final envelope = utf8.encode(
    jsonEncode(<String, Object>{
      'schema': 1,
      'algorithm': 'ed25519',
      'keyId': 'torca-test-key',
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    }),
  );
  return _SignedFixture(
    envelope: Uint8List.fromList(envelope),
    publicKey: publicKey,
  );
}
