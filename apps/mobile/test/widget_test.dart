import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/main.dart';

void main() {
  testWidgets('shows TorChat splash before runtime bootstrap', (tester) async {
    await tester.pumpWidget(const TorChatMobileApp());
    expect(find.text('TorChat'), findsOneWidget);
    expect(find.text('Prywatne wiadomości przez Tor'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
  });
}
