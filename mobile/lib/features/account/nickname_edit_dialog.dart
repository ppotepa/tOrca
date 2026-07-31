import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/ui_operation_registry.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_surface.dart';

class NicknameEditDialog extends ConsumerStatefulWidget {
  const NicknameEditDialog({
    super.key,
    required this.initialNickname,
  });

  final String initialNickname;

  @override
  ConsumerState<NicknameEditDialog> createState() =>
      _NicknameEditDialogState();
}

class _NicknameEditDialogState extends ConsumerState<NicknameEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialNickname,
  );
  String _localError = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.length < 2) {
      setState(() => _localError = 'Nick musi mieć co najmniej 2 znaki.');
      return;
    }
    setState(() => _localError = '');
    await ref.read(appControllerProvider.notifier).setNickname(value);
    if (!mounted) return;
    final result = ref.read(
      uiOperationProvider(UiOperationKey.nicknameSave),
    );
    if (!result.failed) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(
      uiOperationProvider(UiOperationKey.nicknameSave),
    );
    final error = _localError.isNotEmpty ? _localError : operation.error;
    return AlertDialog(
      title: const Text('Edytuj nick'),
      content: BusySurface(
        state: operation,
        label: 'Zapisywanie nicku…',
        child: TextField(
          controller: _controller,
          enabled: !operation.busy,
          autofocus: true,
          maxLength: 32,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Nick',
            errorText: error.isEmpty ? null : error,
          ),
          onSubmitted: (_) {
            if (!operation.busy) _save();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: operation.busy ? null : () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        BusyActionButton(
          busy: operation.busy,
          label: 'Zapisz',
          busyLabel: 'Zapisywanie…',
          onPressed: _save,
        ),
      ],
    );
  }
}
