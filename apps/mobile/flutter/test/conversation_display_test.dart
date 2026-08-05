import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';

void main() {
  test('pairing status display helpers are centralized on InviteState', () {
    expect(InviteState.pending.wireValue, 'PENDING');
    expect(InviteState.pending.outboxIcon, Icons.schedule);

    expect(InviteState.completed.wireValue, 'COMPLETED');
    expect(InviteState.completed.outboxIcon, Icons.check_circle_outline);
  });
}
