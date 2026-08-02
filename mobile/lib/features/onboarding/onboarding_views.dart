import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_theme.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/models/domain.dart';
import '../../shared/async/themed_activity_indicator.dart';
import '../../shared/formatters/invite_code.dart';

export 'onboarding_support_views.dart';

class PairingCodeDialog extends ConsumerStatefulWidget {
  const PairingCodeDialog({
    super.key,
    required this.initialCode,
    this.initialExpiresAt = 0,
    required this.refresh,
    required this.onChanged,
    this.checkRequest,
    this.onAccept,
    this.onReject,
  });

  final String initialCode;
  final int initialExpiresAt;
  final Future<InviteCode?> Function() refresh;
  final ValueChanged<String> onChanged;
  final Future<PairingItem?> Function()? checkRequest;
  final Future<bool> Function(PairingItem request)? onAccept;
  final Future<void> Function(PairingItem request)? onReject;

  @override
  ConsumerState<PairingCodeDialog> createState() => PairingCodeDialogState();
}

class PairingCodeDialogState extends ConsumerState<PairingCodeDialog> {
  late String _code = widget.initialCode;
  late int _expiresAt = widget.initialExpiresAt;
  Timer? _timer;
  int _remaining = 0;
  int _ttlSeconds = 60;
  int _requestCheckTick = 0;
  bool _refreshing = false;
  bool _checkingRequest = false;
  bool _processing = false;
  bool _awaitingContact = false;
  bool _completed = false;
  PairingItem? _request;
  String _error = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateRemaining();
      _requestCheckTick += 1;
      if (_request == null && _requestCheckTick % 2 == 0) {
        unawaited(_checkRequest());
      } else if (_request == null &&
          _remaining == 0 &&
          !_refreshing &&
          !_completed) {
        unawaited(_refresh());
      }
    });
    unawaited(_checkRequest());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateRemaining() {
    if (!mounted || _expiresAt <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = (_expiresAt - now).clamp(0, 999999);
    setState(() {
      _remaining = remaining;
      if (remaining > _ttlSeconds) _ttlSeconds = remaining;
    });
  }

  Future<void> _refresh() async {
    if (_refreshing || _request != null || _completed) return;
    setState(() {
      _refreshing = true;
      _error = '';
      _status = '';
    });
    try {
      final fresh = await widget.refresh();
      final code = fresh?.code ?? '';
      if (!mounted) return;
      if (code.isEmpty) {
        setState(() => _error = 'Nie udało się odświeżyć kodu.');
        return;
      }
      setState(() {
        _code = code;
        _expiresAt = fresh?.expiresAt ?? 0;
        _ttlSeconds =
            (_expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000).clamp(
              1,
              999999,
            );
      });
      widget.onChanged(code);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _checkRequest() async {
    final checkRequest = widget.checkRequest;
    if (checkRequest == null ||
        _checkingRequest ||
        _request != null ||
        _completed) {
      return;
    }
    _checkingRequest = true;
    try {
      final request = await checkRequest();
      if (!mounted || request == null) return;
      setState(() {
        _request = request;
        _error = '';
        _status = '';
      });
    } catch (_) {
      // Pairing reconciliation retries independently.
    } finally {
      _checkingRequest = false;
    }
  }

  Future<void> _accept() async {
    final request = _request;
    final accept = widget.onAccept;
    if (request == null || accept == null || _processing || _awaitingContact) {
      return;
    }
    setState(() {
      _processing = true;
      _error = '';
      _status = '';
    });

    final completion = accept(request);
    try {
      await _waitForLocalDecision(request.id);
      if (mounted) {
        setState(() {
          _processing = false;
          _awaitingContact = true;
          _status =
              'Zaproszenie zaakceptowano. Finalizacja bezpiecznego kontaktu trwa w tle.';
        });
      }

      final contactReady = await completion;
      if (!mounted) return;
      setState(() {
        _processing = false;
        _awaitingContact = !contactReady;
        _completed = contactReady;
        _status = contactReady
            ? ''
            : 'Zaproszenie zaakceptowano. Kontakt pojawi się po zakończeniu wymiany MLS.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _processing = false;
          _awaitingContact = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _waitForLocalDecision(String pairingId) async {
    final key = UiOperationKey.pairingAccept(pairingId);
    var observedBusy = false;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final operation = ref.read(uiOperationProvider(key));
      observedBusy = observedBusy || operation.busy;
      if (observedBusy && !operation.busy) return;
      if (operation.failed) {
        throw StateError(operation.error);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    // The callback may include remote reconciliation. Do not keep the UI busy
    // after the local command window; transition to a domain waiting state.
  }

  Future<void> _reject() async {
    final request = _request;
    if (request == null || _processing || _awaitingContact) return;
    setState(() {
      _processing = true;
      _error = '';
      _status = '';
    });
    try {
      await widget.onReject?.call(request);
      if (mounted) Navigator.pop(context, false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Twój kod parowania'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_completed)
              const _CompletedPairing()
            else if (_request case final request?)
              _PendingPairingDecision(
                request: request,
                processing: _processing,
                awaitingContact: _awaitingContact,
                onAccept: _accept,
                onReject: _reject,
              )
            else
              _PairingCode(code: _code, checkingRequest: _checkingRequest),
            if (_request == null && !_completed && _expiresAt > 0) ...[
              const SizedBox(height: 10),
              Text(
                _refreshing
                    ? 'Odświeżanie kodu…'
                    : _remaining == 0
                    ? 'Kod wygasł · odświeżanie…'
                    : 'Ważny jeszcze ${formatCountdown(_remaining)}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _refreshing
                    ? null
                    : (_remaining / _ttlSeconds).clamp(0, 1),
                minHeight: 3,
              ),
            ],
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _status,
                  style: TextStyle(color: context.statusTheme.warning),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error,
                  style: TextStyle(color: context.statusTheme.danger),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_request == null && !_completed)
              TextButton.icon(
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const ThemedActivityIndicator(compact: true)
                    : const ThemedIcon(Icons.refresh),
                label: Text(_refreshing ? 'Odświeżanie…' : 'Odśwież kod'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _processing ? null : () => Navigator.pop(context),
        child: const Text('Zamknij'),
      ),
    ],
  );
}

/// A recipient-side pairing prompt. Unlike [PairingCodeDialog], this dialog is
/// driven by an already persisted inbox item and is safe to show after the
/// original invite-code sheet has been closed.
class IncomingPairingDialog extends StatefulWidget {
  const IncomingPairingDialog({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onReject,
  });

  final PairingItem request;
  final Future<void> Function() onAccept;
  final Future<void> Function() onReject;

  @override
  State<IncomingPairingDialog> createState() => _IncomingPairingDialogState();
}

class _IncomingPairingDialogState extends State<IncomingPairingDialog> {
  bool _busy = false;
  String _error = '';

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Nowe zaproszenie do kontaktów'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _PendingPairingDecision(
            request: widget.request,
            processing: _busy,
            awaitingContact: false,
            error: _error,
            onReject: () => _run(widget.onReject),
            onAccept: () => _run(widget.onAccept),
          ),
        ),
      ),
    );
  }
}

class _CompletedPairing extends StatelessWidget {
  const _CompletedPairing();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ThemedIcon(
        Icons.check_circle,
        size: 96,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 12),
      Text(
        'Kontakt został dodany',
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 6),
      const Text(
        'Bezpieczne połączenie zostało potwierdzone po obu stronach.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

class _PendingPairingDecision extends StatelessWidget {
  const _PendingPairingDecision({
    required this.request,
    required this.processing,
    required this.awaitingContact,
    required this.onAccept,
    required this.onReject,
    this.error = '',
  });

  final PairingItem request;
  final bool processing;
  final bool awaitingContact;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final String error;

  @override
  Widget build(BuildContext context) {
    final name = request.peer?.nickname.trim();
    return Column(
      children: [
        ThemedIcon(
          awaitingContact ? Icons.schedule : Icons.person_add_alt_1,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          name?.isNotEmpty == true ? name! : 'Nowy kontakt',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          processing
              ? 'Zapisywanie decyzji…'
              : awaitingContact
              ? 'Zaproszenie zaakceptowane. Finalizacja kontaktu przebiega w tle.'
              : 'Zaproszenie oczekuje na Twoją decyzję. Nie zostanie automatycznie odrzucone przez licznik interfejsu.',
          textAlign: TextAlign.center,
        ),
        if (request.peer?.fingerprint.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('Szczegóły bezpieczeństwa'),
            subtitle: const Text('Fingerprint klucza kontaktu'),
            children: [
              SelectableText(
                request.peer!.fingerprint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ],
        if (error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 18),
        if (processing)
          const ThemedActivityIndicator(label: 'Akceptowanie…')
        else if (!awaitingContact)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const ThemedIcon(Icons.close, size: 16),
                  label: const Text('Odrzuć'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAccept,
                  icon: const ThemedIcon(Icons.check, size: 16),
                  label: const Text('Akceptuj'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _PairingCode extends StatelessWidget {
  const _PairingCode({required this.code, required this.checkingRequest});

  final String code;
  final bool checkingRequest;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.all(16),
        child: QrImageView(
          data: code,
          size: 240,
          backgroundColor: Theme.of(context).colorScheme.surface,
          eyeStyle: QrEyeStyle(color: Theme.of(context).colorScheme.onSurface),
          dataModuleStyle: QrDataModuleStyle(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      const SizedBox(height: 8),
      SelectableText(
        formatInviteCode(code),
        style: const TextStyle(
          fontSize: 28,
          letterSpacing: 3,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      const SizedBox(height: 10),
      Text(
        checkingRequest
            ? 'Sprawdzanie nowych zaproszeń…'
            : 'Oczekiwanie na użycie kodu…',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
