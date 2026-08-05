import 'dart:convert';
import 'dart:io';

const nativeKeys = <String, String>{
  'appTitle': 'app_name',
  'notificationNewMessageTitle': 'notification_new_message_title',
  'notificationPairingRequestTitle': 'notification_pairing_request_title',
  'notificationPrivateMessageBody': 'notification_private_message_body',
  'notificationPairingRequestBody': 'notification_pairing_request_body',
};

void main() {
  final resources = Directory('lib/locales/resources');
  final output = Directory('android/app/src/main/res');
  final english = _read(resources, 'app_en.arb');
  final polish = _read(resources, 'app_pl.arb');

  for (final key in nativeKeys.keys) {
    if (!english.containsKey(key) || !polish.containsKey(key)) {
      throw StateError('Missing native ARB key: $key');
    }
  }

  _write(output, 'values/strings.xml', english);
  _write(output, 'values-pl/strings.xml', polish);
}

Map<String, dynamic> _read(Directory directory, String name) =>
    jsonDecode(File('${directory.path}/$name').readAsStringSync())
        as Map<String, dynamic>;

void _write(Directory output, String relativePath, Map<String, dynamic> arb) {
  final file = File('${output.path}/$relativePath')..parent.createSync(recursive: true);
  final lines = <String>['<resources>'];
  for (final entry in nativeKeys.entries) {
    final value = _escape(arb[entry.key] as String);
    lines.add('    <string name="${entry.value}">$value</string>');
  }
  lines.add('</resources>');
  file.writeAsStringSync('${lines.join('\n')}\n');
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", "\\'");
