import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/app/app_theme.dart';
import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/shared/widgets/identity_avatar.dart';
import 'package:torchat_mobile/shared/widgets/list_items.dart';

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

  testWidgets('peer indicator distinguishes unavailable idle and realtime', (
    tester,
  ) async {
    Future<void> show({
      required PeerEndpointStatus endpoint,
      required PeerConnectionStatus connection,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildTorChatTheme(brightness: TorChatBrightnessMode.dark),
        home: Scaffold(
          body: PeerTransportIndicator(
            endpointStatus: endpoint,
            connectionStatus: connection,
            transportPolicy: ContactTransportPolicy.peerOnly,
          ),
        ),
      ),
    );

    await show(
      endpoint: PeerEndpointStatus.missing,
      connection: PeerConnectionStatus.offline,
    );
    expect(find.byTooltip('P2P niedostępne: brak endpointu'), findsOneWidget);

    await show(
      endpoint: PeerEndpointStatus.verified,
      connection: PeerConnectionStatus.offline,
    );
    expect(find.byTooltip('P2P gotowe · idle'), findsOneWidget);

    await show(
      endpoint: PeerEndpointStatus.verified,
      connection: PeerConnectionStatus.connected,
    );
    expect(find.byTooltip('P2P realtime'), findsOneWidget);
  });
}
