import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/app_controller.dart';
import 'package:torchat_flutter_ui/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import 'package:torchat_flutter_ui/async/busy_action_button.dart';
import 'package:torchat_flutter_ui/async/busy_surface.dart';
import '../../shared/formatters/invite_code.dart';
import '../../locales/domain/user_problem.dart';
import '../../locales/domain/user_problem_code.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/problem_localizer.dart';

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
    final state = ref.read(appControllerProvider);
    if (state.problem == null && state.error.isEmpty) {
      Navigator.of(context).pop<void>();
      return;
    }
    setState(() {
      _handled = false;
      _error = state.problem == null
          ? context.l10n.problemOperationFailed
          : localizeProblem(context.l10n, state.problem!);
    });
    await _scanner.start();
  }

  @override
  Widget build(BuildContext context) {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return const ManualInviteCodePage();
    }
    final l10n = context.l10n;
    final operation = ref.watch(
      uiOperationProvider(UiOperationKey.pairingSubmit),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteScanTitle)),
      body: BusySurface(
        state: operation,
        label: l10n.processingCode,
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
    final code = pairingCode(_controller.text);
    if (code == null) {
      setState(
        () => _error = localizeProblem(
          context.l10n,
          const UserProblem(code: UserProblemCode.pairingCodeInvalid),
        ),
      );
      return;
    }
    if (!ref.read(appControllerProvider).transport.connected) {
      setState(
        () => _error = localizeProblem(
          context.l10n,
          const UserProblem(code: UserProblemCode.connectionUnavailable),
        ),
      );
      return;
    }
    setState(() => _error = '');
    await ref.read(appControllerProvider.notifier).submitPairingCode(code);
    if (!mounted) return;
    final state = ref.read(appControllerProvider);
    if (state.problem == null && state.error.isEmpty) {
      Navigator.of(context).pop<void>();
    } else {
      setState(() {
        _error = state.problem == null
            ? context.l10n.problemOperationFailed
            : localizeProblem(context.l10n, state.problem!);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final operation = ref.watch(
      uiOperationProvider(UiOperationKey.pairingSubmit),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addContactTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: BusySurface(
              state: operation,
              label: l10n.processingCode,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ThemedIcon(Icons.qr_code_2, size: 56),
                  const SizedBox(height: 16),
                  Text(
                    l10n.desktopCodeInstructions,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _controller,
                    enabled: !operation.busy,
                    autofocus: true,
                    maxLength: 80,
                    keyboardType: TextInputType.text,
                    inputFormatters: const [PairingCodeInputFormatter()],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!operation.busy) _submit();
                    },
                    decoration: InputDecoration(
                      labelText: l10n.pairingCodeLabel,
                      errorText: _error.isEmpty ? null : _error,
                      prefixIcon: const ThemedIcon(Icons.password),
                    ),
                  ),
                  const SizedBox(height: 12),
                  BusyActionButton(
                    busy: operation.busy,
                    label: l10n.addContactTitle,
                    busyLabel: l10n.processingCode,
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
