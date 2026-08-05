import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_mobile/shared/widgets/tor_status_bar.dart';

void main() {
  testWidgets('lamp exposes separate Tor and P2P state', (tester) async {
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

    expect(find.bySemanticsLabel('Tor: ready · P2P: ready'), findsOneWidget);
    await tester.tap(find.byType(ConnectionStatusLamp));
    expect(opened, isTrue);
  });

  testWidgets('lamp exposes error state without animation dependency', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConnectionStatusLamp(phase: TransportPhase.error)),
      ),
    );

    expect(find.bySemanticsLabel('Tor: error · P2P: error'), findsOneWidget);
  });
}
