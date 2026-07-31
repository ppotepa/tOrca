import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/connection/connection_component.dart';
import 'package:torchat_mobile/core/connection/sequential_connection_sequence.dart';

ConnectionComponentStatus status(
  ConnectionComponent component,
  ConnectionComponentState state,
) => ConnectionComponentStatus(
  component: component,
  state: state,
  detail: component.name,
);

void main() {
  test('early ready facts remain pending behind the first incomplete step', () {
    final result = sequentialConnectionStatuses([
      status(ConnectionComponent.engine, ConnectionComponentState.ready),
      status(ConnectionComponent.localData, ConnectionComponentState.starting),
      status(ConnectionComponent.tor, ConnectionComponentState.ready),
      status(ConnectionComponent.relay, ConnectionComponentState.ready),
      status(ConnectionComponent.peerListener, ConnectionComponentState.ready),
      status(ConnectionComponent.onionService, ConnectionComponentState.ready),
    ]);

    expect(result[0].state, ConnectionComponentState.ready);
    expect(result[1].state, ConnectionComponentState.starting);
    for (var index = 2; index < result.length; index += 1) {
      expect(result[index].state, ConnectionComponentState.pending);
      expect(result[index].detail, contains('Dane lokalne'.toLowerCase()));
    }
  });

  test('only one component can be starting at a time', () {
    final result = sequentialConnectionStatuses([
      status(ConnectionComponent.engine, ConnectionComponentState.ready),
      status(ConnectionComponent.localData, ConnectionComponentState.ready),
      status(ConnectionComponent.tor, ConnectionComponentState.ready),
      status(ConnectionComponent.relay, ConnectionComponentState.starting),
      status(ConnectionComponent.peerListener, ConnectionComponentState.starting),
      status(ConnectionComponent.onionService, ConnectionComponentState.ready),
    ]);

    expect(
      result.where(
        (item) => item.state == ConnectionComponentState.starting,
      ),
      hasLength(1),
    );
    expect(result[3].component, ConnectionComponent.relay);
    expect(result[4].state, ConnectionComponentState.pending);
    expect(result[5].state, ConnectionComponentState.pending);
  });

  test('failure is preserved and blocks every later component', () {
    final result = sequentialConnectionStatuses([
      status(ConnectionComponent.engine, ConnectionComponentState.ready),
      status(ConnectionComponent.localData, ConnectionComponentState.ready),
      status(ConnectionComponent.tor, ConnectionComponentState.failed),
      status(ConnectionComponent.relay, ConnectionComponentState.ready),
      status(ConnectionComponent.peerListener, ConnectionComponentState.ready),
      status(ConnectionComponent.onionService, ConnectionComponentState.ready),
    ]);

    expect(result[2].state, ConnectionComponentState.failed);
    for (var index = 3; index < result.length; index += 1) {
      expect(result[index].state, ConnectionComponentState.pending);
    }
  });
}
