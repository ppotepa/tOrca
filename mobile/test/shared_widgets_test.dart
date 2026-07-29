import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/shared/widgets/action_section.dart';
import 'package:torchat_mobile/shared/widgets/identity_section.dart';
import 'package:torchat_mobile/shared/widgets/pairing_list_section.dart';

void main() {
  testWidgets('identity section renders profile summary and fingerprint', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: IdentitySection(
            title: 'TOŻSAMOŚĆ',
            name: 'Alice',
            subtitle: 'Lokalny profil urządzenia',
            fingerprint: 'AA BB CC',
            selectableFingerprint: true,
          ),
        ),
      ),
    );

    expect(find.text('TOŻSAMOŚĆ'), findsOneWidget);
    expect(find.text('@Alice'), findsOneWidget);
    expect(find.text('Lokalny profil urządzenia'), findsOneWidget);
    expect(find.text('AA BB CC'), findsOneWidget);
  });

  testWidgets('pairing list section renders empty state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PairingListSection<String>(
            title: 'Odebrane',
            items: [],
            emptyMessage: 'Brak odebranych zaproszeń.',
            itemBuilder: _unusedItemBuilder,
          ),
        ),
      ),
    );

    expect(find.text('Odebrane'), findsOneWidget);
    expect(find.text('Brak odebranych zaproszeń.'), findsOneWidget);
  });

  testWidgets('action section renders title and child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ActionSection(title: 'AKCJE', child: Text('Treść sekcji')),
        ),
      ),
    );

    expect(find.text('AKCJE'), findsOneWidget);
    expect(find.text('Treść sekcji'), findsOneWidget);
  });
}

Widget _unusedItemBuilder(BuildContext context, String item) =>
    const SizedBox.shrink();
