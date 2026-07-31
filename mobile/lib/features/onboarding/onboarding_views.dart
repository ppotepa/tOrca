import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/retro_activity_indicator.dart';

export 'onboarding_views_legacy.dart'
    hide PairingCodeDialog, PairingCodeDialogState;

class PairingCodeDialog extends StatefulWidget {
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
  State<PairingCodeDialog> createState() => PairingCodeDialogState();
}

class PairingCodeDialogState extends State<PairingCodeDialog> {
  late String _code = widget.initialCode;
  late int _expiresAt = widget.initialExpiresAt;
  Timer? _timer;
  int _remaining = 0;
  int _ttlSeconds = 60;
  int _requestCheckTick = 0;
  bool _refreshing = false;
  bool _checkingRequest = false;
  bool _processing = false;
  bool _completed = false;
  PairingItem? _request;
  String _error = '';

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
            (_expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000)
                .clamp(1, 999999);
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
      });
    } catch (_) {
      // The global pairing recovery controller retries every two seconds.
    } finally {
      _checkingRequest = false;
    }
  }

  Future<void> _accept() async {
    final request = _request;
    final accept = widget.onAccept;
    if (request == null || accept == null || _processing) return;
    setState(() {
      _processing = true;
      _error = '';
    });
    try {
      final contactReady = await accept(request);
      if (!mounted) return;
      setState(() {
        _processing = false;
        _completed = contactReady;
        if (!contactReady) {
          _error =
              'Zaproszenie zaakceptowano. Kontakt nadal finalizuje bezpieczne połączenie; możesz zamknąć okno, a aplikacja będzie kontynuować synchronizację.';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _reject() async {
    final request = _request;
    if (request == null || _processing) return;
    setState(() {
      _processing = true;
      _error = '';
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
              _CompletedPairing()
            else if (_request case final request?)
              _PendingPairingDecision(
                request: request,
                processing: _processing,
                onAccept: _accept,
                onReject: _reject,
              )
            else
              _PairingCode(
                code: _code,
                checkingRequest: _checkingRequest,
              ),
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
                    ? const RetroActivityIndicator(
                        style: RetroActivityStyle.dots,
                        compact: true,
                      )
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

class _CompletedPairing extends StatelessWidget {
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
    required this.onAccept,
    required this.onReject,
  });

  final PairingItem request;
  final bool processing;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final name = request.peer?.nickname.trim();
    return Column(
      children: [
        ThemedIcon(
          Icons.person_add_alt_1,
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
              ? 'Finalizujemy zaproszenie i czekamy na kontakt po obu stronach…'
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
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        if (processing)
          const RetroActivityIndicator(
            style: RetroActivityStyle.hourglass,
            label: 'Czekamy na zakończenie parowania…',
          )
        else
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
  const _PairingCode({
    required this.code,
    required this.checkingRequest,
  });

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
          eyeStyle: QrEyeStyle(
            color: Theme.of(context).colorScheme.onSurface,
          ),
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
      RetroActivityIndicator(
        style: RetroActivityStyle.dots,
        compact: true,
        label: checkingRequest
            ? 'Sprawdzanie nowych zaproszeń…'
            : 'Oczekiwanie na użycie kodu…',
      ),
    ],
  );
}
