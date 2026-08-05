import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/release/release_info.dart';

final class DiagnosticsExportResult {
  const DiagnosticsExportResult({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

abstract interface class DiagnosticsExportService {
  Future<DiagnosticsExportResult?> export();
}

final class LocalDiagnosticsExportService implements DiagnosticsExportService {
  const LocalDiagnosticsExportService();

  @override
  Future<DiagnosticsExportResult?> export() async {
    final now = DateTime.now().toUtc();
    final timestamp = now
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '-');
    final fileName = 'torca-diagnostics-$timestamp.json.gz';
    final selectedPath = await FilePicker.saveFile(
      dialogTitle: 'Save Torca diagnostics',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const <String>['gz'],
    );
    if (selectedPath == null) return null;

    final payload = <String, Object>{
      'schema': 1,
      'sanitized': true,
      'createdAtUtc': now.toIso8601String(),
      'release': TorcaReleaseInfo.diagnosticMetadata,
      'platform': <String, Object>{
        'operatingSystem': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'locale': Platform.localeName,
        'numberOfProcessors': Platform.numberOfProcessors,
      },
      'privacy': <String, Object>{
        'automaticUpload': false,
        'messagePlaintextIncluded': false,
        'attachmentPayloadIncluded': false,
        'privateKeysIncluded': false,
        'pairingCodesIncluded': false,
        'capabilityTokensIncluded': false,
      },
    };
    final encoded = utf8.encode(const JsonEncoder.withIndent('  ').convert(payload));
    final compressed = GZipCodec(level: 9).encode(encoded);

    var destination = selectedPath;
    if (!destination.toLowerCase().endsWith('.gz')) {
      destination = '$destination.gz';
    }
    try {
      final output = File(destination);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(compressed, flush: true);
      return DiagnosticsExportResult(path: output.path, bytes: compressed.length);
    } on FileSystemException {
      final fallbackRoot = await getApplicationDocumentsDirectory();
      final fallback = File('${fallbackRoot.path}${Platform.pathSeparator}$fileName');
      await fallback.parent.create(recursive: true);
      await fallback.writeAsBytes(compressed, flush: true);
      return DiagnosticsExportResult(path: fallback.path, bytes: compressed.length);
    }
  }
}
