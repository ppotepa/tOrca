import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/shared/widgets/tor_status_bar.dart';

void main() {
  testWidgets('lamp exposes ready state and opens diagnostics', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionStatusLamp(
            phase: TransportPhase.connected,
            peerStatus: PeerServerStatus.ready,
            onOpenConnectionCenter: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Gotowe: Tor i P2P są dostępne'), findsOneWidget);
    await tester.tap(find.byType(ConnectionStatusLamp));
    expect(opened, isTrue);
  });

  testWidgets('lamp exposes error state without animation dependency', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionStatusLamp(phase: TransportPhase.error),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Błąd komunikacji'), findsOneWidget);
  });
}
