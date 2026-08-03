import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/shared/widgets/identity_avatar.dart';

void main() {
  test('activity labels describe the person rather than the transport', () {
    expect(contactActivityLabel(ContactActivityVisualState.typing), 'pisze…');
    expect(
      contactActivityLabel(ContactActivityVisualState.online),
      'aktywny w aplikacji',
    );
    expect(
      contactActivityLabel(ContactActivityVisualState.online),
      'aktywny w aplikacji',
    );
  });
}
