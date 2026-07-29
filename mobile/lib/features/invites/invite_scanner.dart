import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../shared/formatters/invite_code.dart';

class InviteScannerPage extends StatelessWidget {
  const InviteScannerPage({super.key});

  @override
  Widget build(BuildContext context) {
    // mobile_scanner has no Windows/Linux/macOS implementation. Never mount
    // the widget on desktop: merely creating it attempts to call its native
    // method channel and produces MissingPluginException.
    if (Platform.isAndroid || Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: const Text('Zeskanuj kod parowania')),
        body: MobileScanner(
          onDetect: (capture) {
            final value = firstPairingCode(
              capture.barcodes.map((barcode) => barcode.rawValue),
            );
            if (value != null && context.mounted) {
              Navigator.of(context).pop(value);
            }
          },
        ),
      );
    }
    return const ManualInviteCodePage();
  }
}

class ManualInviteCodePage extends StatefulWidget {
  const ManualInviteCodePage({super.key});

  @override
  State<ManualInviteCodePage> createState() => _ManualInviteCodePageState();
}

class _ManualInviteCodePageState extends State<ManualInviteCodePage> {
  final _controller = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = pairingCodeDigits(_controller.text);
    if (code == null) {
      setState(() => _error = 'Kod musi zawierać dokładnie 8 cyfr.');
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Dodaj kontakt')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_2, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Desktop nie używa kamery. Wpisz 8-cyfrowy kod wyświetlony na drugim urządzeniu.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLength: 9,
                keyboardType: TextInputType.number,
                inputFormatters: const [PairingCodeInputFormatter()],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Kod parowania',
                  errorText: _error.isEmpty ? null : _error,
                  prefixIcon: const Icon(Icons.password),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Dodaj kontakt'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
