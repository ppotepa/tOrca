import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torchat_mobile/core/runtime/operation_journal.dart';

void main() {
  test('reuses stable operation id after journal recreation', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final first = OperationJournal(await SharedPreferences.getInstance());
    final created = await first.commandId(
      operation: 'delete_message',
      stableId: 'message-1',
    );
    final second = OperationJournal(await SharedPreferences.getInstance());
    expect(
      await second.commandId(
        operation: 'delete_message',
        stableId: 'message-1',
      ),
      created,
    );
  });

  test('bounds journal retention', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final journal = OperationJournal(await SharedPreferences.getInstance());
    for (var index = 0; index < OperationJournal.maxEntries + 10; index++) {
      await journal.commandId(
        operation: 'mutation',
        stableId: 'id-$index',
      );
    }
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('torchat.operation-command-ids');
    expect(raw, isNotNull);
    expect(raw!.split('mutation:').length - 1, OperationJournal.maxEntries);
  });
}
