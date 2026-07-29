import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';
import '../../shared/formatters/operation_status.dart';
import '../../shared/formatters/conversation_display.dart';
import '../../shared/widgets/feature_header.dart';
import '../../shared/widgets/identity_avatar.dart';
import '../../shared/widgets/pairing_cards.dart';
import '../../shared/widgets/pairing_list_section.dart';
import '../../shared/widgets/status_banner.dart';

class InboxView extends StatefulWidget {
  const InboxView({
    super.key,
    required this.inbox,
    required this.outbox,
    required this.onAccept,
    required this.onReject,
    required this.onArchive,
    required this.onCancel,
    this.error = '',
    this.notice = '',
    this.action = '',
  });

  final List<ContactRequest> inbox;
  final List<PairingItem> outbox;
  final ValueChanged<ContactRequest> onAccept;
  final ValueChanged<ContactRequest> onReject;
  final ValueChanged<ContactRequest> onArchive;
  final ValueChanged<PairingItem> onCancel;
  final String error;
  final String notice;
  final String action;

  @override
  State<InboxView> createState() => _InboxViewState();
}

class _InboxViewState extends State<InboxView> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const SizedBox(height: 4),
      FeatureHeader(title: 'Inbox', subtitle: 'Zaproszenia do rozmów'),
      const SizedBox(height: 10),
      SegmentedButton<int>(
        segments: [
          ButtonSegment(
            value: 0,
            icon: const ThemedIcon(Icons.move_to_inbox_outlined),
            label: Text('Inbox (${widget.inbox.length})'),
          ),
          ButtonSegment(
            value: 1,
            icon: const ThemedIcon(Icons.outbox_outlined),
            label: Text('Outbox (${widget.outbox.length})'),
          ),
        ],
        selected: {_tab},
        onSelectionChanged: (value) => setState(() => _tab = value.first),
      ),
      const SizedBox(height: 12),
      if (widget.notice.isNotEmpty)
        StatusBanner(
          message: widget.notice,
          color: context.statusTheme.success,
        ),
      if (widget.error.isNotEmpty)
        StatusBanner(message: widget.error, color: context.statusTheme.danger),
      if (_tab == 0)
        PairingListSection<ContactRequest>(
          title: 'Odebrane',
          items: widget.inbox,
          emptyMessage: 'Brak odebranych zaproszeń.',
          emptyIcon: Icons.inbox_outlined,
          itemBuilder: (context, request) => Dismissible(
            key: ValueKey(request.id),
            direction:
                request.can(PairingAvailableAction.accept) ||
                    request.can(PairingAvailableAction.reject)
                ? DismissDirection.horizontal
                : request.can(PairingAvailableAction.archive)
                ? DismissDirection.endToStart
                : DismissDirection.none,
            confirmDismiss: (direction) async {
              if (direction == DismissDirection.startToEnd) {
                if (request.can(PairingAvailableAction.reject)) {
                  widget.onReject(request);
                } else if (request.can(PairingAvailableAction.archive)) {
                  widget.onArchive(request);
                }
                return false;
              }
              if (direction == DismissDirection.endToStart) {
                if (request.can(PairingAvailableAction.accept)) {
                  widget.onAccept(request);
                } else if (request.can(PairingAvailableAction.archive)) {
                  widget.onArchive(request);
                }
                return false;
              }
              return false;
            },
            background: _SwipeAction(
              alignment: Alignment.centerLeft,
              color: request.can(PairingAvailableAction.reject)
                  ? context.inboxTheme.reject
                  : context.inboxTheme.archive,
              icon: request.can(PairingAvailableAction.reject)
                  ? Icons.close
                  : Icons.block_outlined,
              label: request.can(PairingAvailableAction.reject)
                  ? 'Odrzuć'
                  : 'Archiwizuj',
              radius: context.inboxTheme.actionRadius,
              foreground: request.can(PairingAvailableAction.reject)
                  ? context.inboxTheme.rejectForeground
                  : context.inboxTheme.archiveForeground,
            ),
            secondaryBackground: _SwipeAction(
              alignment: Alignment.centerRight,
              color: request.can(PairingAvailableAction.accept)
                  ? context.inboxTheme.accept
                  : context.inboxTheme.archive,
              icon: request.can(PairingAvailableAction.accept)
                  ? Icons.check
                  : Icons.archive_outlined,
              label: request.can(PairingAvailableAction.accept)
                  ? 'Akceptuj'
                  : 'Archiwizuj',
              radius: context.inboxTheme.actionRadius,
              foreground: request.can(PairingAvailableAction.accept)
                  ? context.inboxTheme.acceptForeground
                  : context.inboxTheme.archiveForeground,
            ),
            child: _InboxCard(
              request: request,
              action: widget.action,
              onAccept: widget.onAccept,
              onReject: widget.onReject,
              onArchive: widget.onArchive,
            ),
          ),
        )
      else
        PairingListSection<PairingItem>(
          title: 'Wysłane',
          items: widget.outbox,
          emptyMessage: 'Brak wysłanych zaproszeń.',
          emptyIcon: Icons.outbox_outlined,
          itemBuilder: (context, request) => _OutboxCard(
            request: request,
            action: widget.action,
            onCancel: widget.onCancel,
          ),
        ),
    ],
  );
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({
    required this.request,
    required this.action,
    required this.onAccept,
    required this.onReject,
    required this.onArchive,
  });

  final ContactRequest request;
  final String action;
  final ValueChanged<ContactRequest> onAccept;
  final ValueChanged<ContactRequest> onReject;
  final ValueChanged<ContactRequest> onArchive;

  @override
  Widget build(BuildContext context) {
    final canAccept = request.can(PairingAvailableAction.accept);
    final canReject = request.can(PairingAvailableAction.reject);
    final canArchive = request.can(PairingAvailableAction.archive);
    final archiveAvailable = request.can(PairingAvailableAction.archive);
    final theme = context.inboxTheme;

    return PairingRecordCard(
      pendingBorderColor: theme.archive,
      leading: IdentityAvatar(label: request.peer.nickname),
      title: '@${request.peer.nickname}',
      subtitle: '${request.peer.fingerprint}\n${request.status.label}',
      status: request.status,
      pendingTrailing: Wrap(
        spacing: 8,
        children: [
          if (canAccept)
            FilledButton(
              onPressed: action.isEmpty && canAccept
                  ? () => onAccept(request)
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: Size(theme.actionMinWidth, theme.actionMinHeight),
                backgroundColor: theme.accept,
                foregroundColor: theme.acceptForeground,
                padding: EdgeInsets.symmetric(
                  horizontal: theme.actionPaddingHorizontal,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(theme.actionRadius),
                ),
              ),
              child: action == OperationAction.acceptPairing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : ThemedIcon(Icons.check, size: theme.actionIconSize),
            ),
          if (canReject)
            OutlinedButton(
              onPressed: action.isEmpty && canReject
                  ? () => onReject(request)
                  : null,
              style: OutlinedButton.styleFrom(
                minimumSize: Size(theme.actionMinWidth, theme.actionMinHeight),
                padding: EdgeInsets.symmetric(
                  horizontal: theme.actionPaddingHorizontal,
                  vertical: 10,
                ),
                side: BorderSide(color: theme.reject),
                foregroundColor: theme.rejectForeground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(theme.actionRadius),
                ),
              ),
              child: ThemedIcon(Icons.close, size: theme.actionIconSize),
            ),
        ],
      ),
      completedTrailing: archiveAvailable
          ? TextButton.icon(
              onPressed: action.isEmpty && canArchive
                  ? () => onArchive(request)
                  : null,
              style: TextButton.styleFrom(
                foregroundColor: theme.archiveForeground,
                padding: EdgeInsets.symmetric(
                  horizontal: theme.actionPaddingHorizontal,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(theme.actionRadius),
                ),
              ),
              icon: ThemedIcon(
                Icons.archive_outlined,
                size: theme.actionIconSize,
              ),
              label: const Text('Archiwizuj'),
            )
          : PairingStatusChip(label: request.status.label),
    );
  }
}

class _SwipeAction extends StatelessWidget {
  const _SwipeAction({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
    required this.radius,
    required this.foreground,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;
  final double radius;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = context.inboxTheme;
    return Container(
      alignment: alignment,
      padding: EdgeInsets.symmetric(
        horizontal: theme.actionPaddingHorizontal,
        vertical: 10,
      ),
      height: theme.actionMinHeight + 22,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemedIcon(icon, color: foreground, size: theme.actionIconSize),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutboxCard extends StatelessWidget {
  const _OutboxCard({
    required this.request,
    required this.action,
    required this.onCancel,
  });

  final PairingItem request;
  final String action;
  final ValueChanged<PairingItem> onCancel;

  @override
  Widget build(BuildContext context) {
    final canCancel = request.can(PairingAvailableAction.cancel);
    final theme = context.inboxTheme;
    return PairingRecordCard(
      leading: CircleAvatar(child: ThemedIcon(request.status.outboxIcon)),
      title: outboxTitle(request),
      subtitle: 'Kod został przyjęty przez relay\n${request.status.label}',
      status: request.status,
      pendingTrailing: TextButton.icon(
        onPressed: action.isEmpty && canCancel ? () => onCancel(request) : null,
        style: TextButton.styleFrom(
          foregroundColor: theme.archiveForeground,
          padding: EdgeInsets.symmetric(
            horizontal: theme.actionPaddingHorizontal,
            vertical: 10,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(theme.actionRadius),
          ),
        ),
        icon: ThemedIcon(Icons.cancel_outlined, size: theme.actionIconSize),
        label: const Text('Anuluj'),
      ),
      completedTrailing: PairingStatusChip(label: request.status.label),
    );
  }
}
