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
    this.checkUsed,
  });
  final String initialCode;
  final int initialExpiresAt;
  final Future<InviteCode?> Function() refresh;
  final ValueChanged<String> onChanged;
  final Future<bool> Function()? checkUsed;
  @override
  State<PairingCodeDialog> createState() => PairingCodeDialogState();
}

class PairingCodeDialogState extends State<PairingCodeDialog> {
  late String _code = widget.initialCode;
  Timer? _timer;
  int _remaining = 0;
  int _ttlSeconds = 60;
  bool _refreshing = false;
  bool _checkingUsed = false;
  bool _used = false;
  int _usedCheckTick = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateRemaining();
      _usedCheckTick += 1;
      if (_usedCheckTick % 2 == 0) unawaited(_checkUsed());
      if (_remaining == 0 && !_refreshing) _refresh();
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
    if (_refreshing || _used) return;
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

  Future<void> _checkUsed() async {
    final checkUsed = widget.checkUsed;
    if (checkUsed == null || _checkingUsed || _used) return;
    _checkingUsed = true;
    try {
      final used = await checkUsed();
      if (!mounted || !used) return;
      setState(() {
        _used = true;
        _error = '';
      });
      _timer?.cancel();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 850), () {
          if (mounted) Navigator.pop(context, true);
        }),
      );
    } catch (_) {
      // The dialog remains useful even if a background inbox poll fails.
    } finally {
      _checkingUsed = false;
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
            if (_used) ...[
              Icon(
                Icons.check_circle,
                size: 104,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Kod został użyty',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text('Otwieram Inbox.', textAlign: TextAlign.center),
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
            if (_expiresAt > 0) ...[
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
              onPressed: _refreshing || _used ? null : _refresh,
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
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
          Icon(
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
                Icon(
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
                    const Icon(Icons.eco_outlined, size: 18),
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
                    icon: const Icon(Icons.refresh),
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
              Icon(
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
                  Icon(
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
