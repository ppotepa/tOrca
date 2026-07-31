import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_readiness.dart';

class NicknameOnboardingScreen extends StatelessWidget {
  const NicknameOnboardingScreen({
    super.key,
    required this.controller,
    required this.connection,
    required this.error,
    required this.onSave,
  });

  final TextEditingController controller;
  final ConnectionReadiness connection;
  final String error;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final canSave = connection.onboardingReady;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ThemedIcon(
                    canSave ? Icons.check_circle_outline : Icons.sync,
                    size: 64,
                    color: canSave
                        ? context.statusTheme.success
                        : context.statusTheme.warning,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    canSave
                        ? 'TorChat jest gotowy'
                        : 'Przywracanie gotowości komunikacji…',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    canSave
                        ? 'Relay i onion tego urządzenia są aktywne. Ustaw lokalną nazwę użytkownika.'
                        : 'Wpisany nick zostanie zachowany. Zapis będzie dostępny po przywróceniu relaya i lokalnego onion.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 32,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (canSave) onSave();
                    },
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
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.statusTheme.danger),
                      ),
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: canSave ? onSave : null,
                      child: const Text('Zapisz nick'),
                    ),
                  ),
                  if (!canSave) ...[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
