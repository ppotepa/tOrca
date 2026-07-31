import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../shared/async/busy_action_button.dart';
import '../../shared/async/busy_surface.dart';
import '../../shared/formatters/invite_code.dart';

class InviteScannerPage extends ConsumerStatefulWidget {
  const InviteScannerPage({super.key});

  @override
  ConsumerState<InviteScannerPage> createState() => _InviteScannerPageState();
}

class _InviteScannerPageState extends ConsumerState<InviteScannerPage> {
  final MobileScannerController _scanner = MobileScannerController();
  String _error = '';
  bool _handled = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _submit(String code) async {
    if (_handled) return;
    _handled = true;
    await _scanner.stop();
    setState(() => _error = '');
    await ref.read(appControllerProvider.notifier).submitPairingCode(code);
    if (!mounted) return;
    final error = ref.read(appControllerProvider).error;
    if (error.isEmpty) {
      Navigator.of(context).pop<void>();
      return;
    }
    setState(() {
      _handled = false;
      _error = error;
    });
    await _scanner.start();
  }

  @override
  Widget build(BuildContext context) {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return const ManualInviteCodePage();
    }
    final operation = ref.watch(
      uiOperationProvider(UiOperationKey.pairingSubmit),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Zeskanuj kod parowania')),
      body: BusySurface(
        state: operation,
        label: 'Przetwarzanie kodu…',
        child: Stack(
          children: [
            MobileScanner(
              controller: _scanner,
              onDetect: (capture) {
                final value = firstPairingCode(
                  capture.barcodes.map((barcode) => barcode.rawValue),
                );
                if (value != null) _submit(value);
              },
            ),
            if (_error.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ManualInviteCodePage extends ConsumerStatefulWidget {
  const ManualInviteCodePage({super.key});

  @override
  ConsumerState<ManualInviteCodePage> createState() =>
      _ManualInviteCodePageState();
}

class _ManualInviteCodePageState extends ConsumerState<ManualInviteCodePage> {
  final _controller = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = pairingCodeDigits(_controller.text);
    if (code == null) {
      setState(() => _error = 'Kod musi zawierać dokładnie 8 cyfr.');
      return;
    }
    setState(() => _error = '');
    await ref.read(appControllerProvider.notifier).submitPairingCode(code);
    if (!mounted) return;
    final error = ref.read(appControllerProvider).error;
    if (error.isEmpty) {
      Navigator.of(context).pop<void>();
    } else {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(
      uiOperationProvider(UiOperationKey.pairingSubmit),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Dodaj kontakt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: BusySurface(
              state: operation,
              label: 'Przetwarzanie kodu…',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ThemedIcon(Icons.qr_code_2, size: 56),
                  const SizedBox(height: 16),
                  const Text(
                    'Desktop nie używa kamery. Wpisz 8-cyfrowy kod wyświetlony na drugim urządzeniu.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _controller,
                    enabled: !operation.busy,
                    autofocus: true,
                    maxLength: 9,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [PairingCodeInputFormatter()],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!operation.busy) _submit();
                    },
                    decoration: InputDecoration(
                      labelText: 'Kod parowania',
                      errorText: _error.isEmpty ? null : _error,
                      prefixIcon: const ThemedIcon(Icons.password),
                    ),
                  ),
                  const SizedBox(height: 12),
                  BusyActionButton(
                    busy: operation.busy,
                    label: 'Dodaj kontakt',
                    busyLabel: 'Przetwarzanie…',
                    icon: const ThemedIcon(Icons.arrow_forward),
                    onPressed: _submit,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
