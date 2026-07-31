import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_mobile/core/attachments/encrypted_image_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('automatic image download is private by default and persists', () async {
    expect(
      await ImageAttachmentPreferences.automaticDownloadEnabled(),
      isFalse,
    );

    await ImageAttachmentPreferences.setAutomaticDownloadEnabled(true);

    expect(
      await ImageAttachmentPreferences.automaticDownloadEnabled(),
      isTrue,
    );
  });
}
