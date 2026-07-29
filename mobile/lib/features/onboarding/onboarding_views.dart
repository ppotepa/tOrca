import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/models/domain.dart';
import '../../app/app_theme.dart';
import '../../shared/formatters/invite_code.dart';
import '../../shared/widgets/tor_status_bar.dart';

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
  Timer? _timer;
  int _remaining = 0;
  int _ttlSeconds = 60;
  bool _refreshing = false;
  bool _checkingRequest = false;
  bool _processing = false;
  bool _completed = false;
  int _requestCheckTick = 0;
  int _approvalRemaining = 15;
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
      }
      if (_request != null && !_processing && !_completed) {
        setState(() => _approvalRemaining -= 1);
        if (_approvalRemaining <= 0) unawaited(_reject(expired: true));
      } else if (_remaining == 0 && !_refreshing && !_completed) {
        _refresh();
      }
    });
  }

  void _updateRemaining() {
    if (!mounted) return;
    final expiresAt = widgetExpiresAt;
    if (expiresAt <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = (expiresAt - now).clamp(0, 999999);
    setState(() {
      _remaining = remaining;
      if (remaining > _ttlSeconds) _ttlSeconds = remaining;
    });
  }

  int get widgetExpiresAt => _expiresAt;
  late int _expiresAt = widget.initialExpiresAt;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || _request != null || _completed) return;
    setState(() => _refreshing = true);
    try {
      final fresh = await widget.refresh();
      final code = fresh?.code ?? '';
      if (mounted && code.isNotEmpty) {
        setState(() {
          _code = code;
          _expiresAt = fresh?.expiresAt ?? 0;
          _ttlSeconds =
              (_expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000)
                  .clamp(1, 999999);
          _error = '';
        });
        widget.onChanged(code);
      }
      if (mounted && code.isEmpty) {
        setState(() => _error = 'Nie udało się odświeżyć kodu.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _checkRequest() async {
    final checkRequest = widget.checkRequest;
    if (checkRequest == null || _checkingRequest || _request != null) return;
    _checkingRequest = true;
    try {
      final request = await checkRequest();
      if (!mounted || request == null) return;
      setState(() {
        _request = request;
        _approvalRemaining = 15;
        _error = '';
      });
    } catch (_) {
      // The dialog remains useful even if a background inbox poll fails.
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
              'Zaproszenie zaakceptowano, ale bezpieczne połączenie nie zostało jeszcze ukończone.';
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

  Future<void> _reject({bool expired = false}) async {
    final request = _request;
    if (request == null || _processing) return;
    setState(() => _processing = true);
    try {
      await widget.onReject?.call(request);
      if (!mounted) return;
      Navigator.pop(context, false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = expired
              ? 'Nie udało się zamknąć wygasłego żądania.'
              : error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Twój kod parowania'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_completed) ...[
              ThemedIcon(
                Icons.check_circle,
                size: 104,
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
                'Bezpieczne połączenie zostało potwierdzone.',
                textAlign: TextAlign.center,
              ),
            ] else if (_request case final request?) ...[
              ThemedIcon(
                Icons.person_add_alt_1,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                request.peer?.nickname.trim().isNotEmpty == true
                    ? request.peer!.nickname
                    : 'Nowy kontakt',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Chce dodać Cię do kontaktów',
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
              const SizedBox(height: 18),
              Text(
                'Zaakceptuj w ciągu $_approvalRemaining s',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (_approvalRemaining / 15).clamp(0, 1),
                minHeight: 6,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _processing ? null : _reject,
                      child: const Text('Odrzuć'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _processing ? null : _accept,
                      child: _processing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Akceptuj'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.all(16),
                child: QrImageView(
                  data: _code,
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
                formatInviteCode(_code),
                style: const TextStyle(
                  fontSize: 28,
                  letterSpacing: 3,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (_request == null && !_completed && _expiresAt > 0) ...[
              const SizedBox(height: 8),
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
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: TextStyle(color: context.statusTheme.danger),
                ),
              ),
            TextButton.icon(
              onPressed: _refreshing || _request != null || _completed
                  ? null
                  : _refresh,
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const ThemedIcon(Icons.refresh),
              label: const Text('Odśwież kod'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Zamknij'),
      ),
    ],
  );
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemedIcon(
            Icons.eco,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(height: 16),
          Text(
            'TorChat',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text('Prywatne wiadomości przez Tor'),
        ],
      ),
    ),
  );
}

class BootScreen extends StatelessWidget {
  const BootScreen({
    super.key,
    required this.phase,
    required this.status,
    required this.detail,
    required this.progress,
    required this.error,
    required this.retry,
    required this.connecting,
  });
  final TransportPhase phase;
  final String status, detail, error;
  final int? progress;
  final VoidCallback retry;
  final bool connecting;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ThemedIcon(
                  Icons.eco,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'TorChat',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text('Prywatne wiadomości przez Tor'),
                const SizedBox(height: 30),
                Text(
                  switch (phase) {
                    TransportPhase.starting ||
                    TransportPhase.bootstrapping => 'Rozgrzewanie sieci Tor',
                    TransportPhase.connecting || TransportPhase.reconnecting =>
                      'Łączenie z serwerem TorChat',
                    TransportPhase.connected => 'Połączono',
                    _ => 'Sprawdzanie połączenia',
                  },
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const ThemedIcon(Icons.eco_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(status, textAlign: TextAlign.left)),
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress! / 100),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text('$progress%'),
                  ),
                ],
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(detail, textAlign: TextAlign.center),
                ],
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.statusTheme.danger),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: retry,
                    icon: const ThemedIcon(Icons.refresh),
                    label: const Text('Spróbuj ponownie'),
                  ),
                ] else if (connecting) ...[
                  const SizedBox(height: 22),
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class TorScreen extends StatelessWidget {
  const TorScreen({
    super.key,
    required this.status,
    required this.detail,
    required this.progress,
    required this.error,
    required this.retry,
    required this.connecting,
  });
  final String status, detail, error;
  final int? progress;
  final VoidCallback retry;
  final bool connecting;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                Icons.eco,
                size: 64,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(height: 18),
              Text(
                status,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (progress != null) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(value: progress! / 100),
                const SizedBox(height: 8),
                Text('$progress%'),
              ],
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(detail, textAlign: TextAlign.center),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.statusTheme.danger),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: retry,
                  child: const Text('Spróbuj ponownie'),
                ),
              ],
              if (error.isEmpty && connecting)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class NicknameScreen extends StatelessWidget {
  const NicknameScreen({
    super.key,
    required this.controller,
    required this.transport,
    required this.error,
    required this.onSave,
  });
  final TextEditingController controller;
  final String error;
  final RuntimeTorStatus transport;
  final VoidCallback onSave;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          TorStatusBar(
            status: transport.label,
            phase: transport.phase,
            latencyMs: transport.latencyMs,
            desktop: true,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ThemedIcon(
                    Icons.person_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Ustaw swój nick',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    transport.connected
                        ? 'Połączono z relayem. Konto lokalne jest gotowe.'
                        : 'Łączenie z relayem przez Tor…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    onSubmitted: (_) => onSave(),
                    decoration: const InputDecoration(
                      labelText: 'Nick',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error,
                        style: TextStyle(color: context.statusTheme.danger),
                      ),
                    ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: transport.connected ? onSave : null,
                    child: const Text('Zapisz nick'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
