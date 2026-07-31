import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../formatters/operation_status.dart';
import 'retro_activity_indicator.dart';

class ActionStatusStrip extends ConsumerStatefulWidget {
  const ActionStatusStrip({super.key, required this.action});

  final String action;

  @override
  ConsumerState<ActionStatusStrip> createState() => _ActionStatusStripState();
}

class _ActionStatusStripState extends ConsumerState<ActionStatusStrip> {
  String? _busyPairingId;
  String _busyPairingAction = '';

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final operation = operationLabel(widget.action);
    final incoming = _firstIncoming(appState.inbox);
    final outgoing = _firstOutgoing(appState.outbox);

    if (operation == null && incoming == null && outgoing == null) {
      return const SizedBox.shrink();
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (operation != null)
            _OperationPanel(
              label: operation,
              pairingAction: _isPairingAction(widget.action),
            ),
          if (incoming != null)
            _IncomingPairingPanel(
              item: incoming,
              busyAction: _busyPairingId == incoming.id
                  ? _busyPairingAction
                  : '',
              onAccept: () => _runPairingAction(
                incoming,
                OperationAction.acceptPairing,
                () => controller.acceptPairing(incoming.id),
              ),
              onReject: () => _runPairingAction(
                incoming,
                OperationAction.rejectPairing,
                () => controller.rejectPairing(incoming.id),
              ),
            )
          else if (outgoing != null)
            _OutgoingPairingPanel(
              item: outgoing,
              busyAction: _busyPairingId == outgoing.id
                  ? _busyPairingAction
                  : '',
              onCancel: outgoing.can(PairingAvailableAction.cancel)
                  ? () => _runPairingAction(
                      outgoing,
                      OperationAction.cancelPairing,
                      () => controller.cancelPairing(outgoing.id),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _runPairingAction(
    PairingItem item,
    String action,
    Future<void> Function() operation,
  ) async {
    if (_busyPairingId != null) return;
    setState(() {
      _busyPairingId = item.id;
      _busyPairingAction = action;
    });
    try {
      await operation();
    } finally {
      if (mounted && _busyPairingId == item.id) {
        setState(() {
          _busyPairingId = null;
          _busyPairingAction = '';
        });
      }
    }
  }
}

class _OperationPanel extends StatelessWidget {
  const _OperationPanel({
    required this.label,
    required this.pairingAction,
  });

  final String label;
  final bool pairingAction;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: context.statusTheme.statusBackground,
      border: Border(
        bottom: BorderSide(color: context.statusTheme.statusBorder),
      ),
    ),
    child: RetroActivityIndicator(
      style: pairingAction
          ? RetroActivityStyle.hourglass
          : RetroActivityStyle.dots,
      compact: true,
      label: label,
    ),
  );
}

class _IncomingPairingPanel extends StatelessWidget {
  const _IncomingPairingPanel({
    required this.item,
    required this.busyAction,
    required this.onAccept,
    required this.onReject,
  });

  final PairingItem item;
  final String busyAction;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final peerName = _peerName(item);
    final accepting = busyAction == OperationAction.acceptPairing;
    final rejecting = busyAction == OperationAction.rejectPairing;
    final busy = busyAction.isNotEmpty;

    return Material(
      color: context.statusTheme.statusBackground,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        child: Row(
          children: [
            const ThemedIcon(Icons.person_add_alt_1, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nowe zaproszenie od $peerName',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    busy
                        ? 'Czekamy na zakończenie operacji i synchronizację kontaktu…'
                        : 'Potwierdź lub odrzuć prośbę o kontakt.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onReject,
              icon: rejecting
                  ? const RetroActivityIndicator(
                      style: RetroActivityStyle.dots,
                      compact: true,
                    )
                  : const ThemedIcon(Icons.close, size: 16),
              label: Text(rejecting ? 'Odrzucanie…' : 'Odrzuć'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy ? null : onAccept,
              icon: accepting
                  ? const RetroActivityIndicator(
                      style: RetroActivityStyle.hourglass,
                      compact: true,
                    )
                  : const ThemedIcon(Icons.check, size: 16),
              label: Text(accepting ? 'Akceptowanie…' : 'Akceptuj'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutgoingPairingPanel extends StatelessWidget {
  const _OutgoingPairingPanel({
    required this.item,
    required this.busyAction,
    required this.onCancel,
  });

  final PairingItem item;
  final String busyAction;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final cancelling = busyAction == OperationAction.cancelPairing;
    return Material(
      color: context.statusTheme.statusBackground,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        child: Row(
          children: [
            const RetroActivityIndicator(
              style: RetroActivityStyle.dots,
              compact: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Zaproszenie do ${_peerName(item)} oczekuje',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    item.status == InviteState.accepted
                        ? 'Druga strona zaakceptowała. Finalizujemy bezpieczny kontakt…'
                        : 'Czekamy na akceptację drugiej strony.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (onCancel != null)
              OutlinedButton.icon(
                onPressed: busyAction.isEmpty ? onCancel : null,
                icon: cancelling
                    ? const RetroActivityIndicator(
                        style: RetroActivityStyle.dots,
                        compact: true,
                      )
                    : const ThemedIcon(Icons.cancel_outlined, size: 16),
                label: Text(cancelling ? 'Anulowanie…' : 'Anuluj'),
              ),
          ],
        ),
      ),
    );
  }
}

PairingItem? _firstIncoming(List<PairingItem> items) {
  for (final item in items) {
    if (item.status == InviteState.pending &&
        (item.can(PairingAvailableAction.accept) ||
            item.can(PairingAvailableAction.reject))) {
      return item;
    }
  }
  return null;
}

PairingItem? _firstOutgoing(List<PairingItem> items) {
  for (final item in items) {
    if (item.status == InviteState.pending ||
        item.status == InviteState.accepted) {
      return item;
    }
  }
  return null;
}

String _peerName(PairingItem item) {
  final nickname = item.peer?.nickname.trim() ?? '';
  if (nickname.isNotEmpty) return nickname;
  final id = item.peer?.id.trim() ?? '';
  return id.isEmpty ? 'nowego kontaktu' : id;
}

bool _isPairingAction(String action) => switch (action) {
  OperationAction.refreshPairing ||
  OperationAction.submitPairing ||
  OperationAction.acceptPairing ||
  OperationAction.rejectPairing ||
  OperationAction.archivePairing ||
  OperationAction.cancelPairing => true,
  _ => false,
};
