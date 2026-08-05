import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_mobile/core/attachments/encrypted_image_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'automatic encrypted image materialization is enabled by default',
    () async {
      expect(
        await ImageAttachmentPreferences.automaticDownloadEnabled(),
        isTrue,
      );

      await ImageAttachmentPreferences.setAutomaticDownloadEnabled(false);

      expect(
        await ImageAttachmentPreferences.automaticDownloadEnabled(),
        isFalse,
      );
    },
  );
}
