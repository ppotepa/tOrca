import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

enum ContactActivityVisualState { unknown, offline, away, online, typing }

String contactActivityLabel(
  ContactActivityVisualState state, {
  int? lastSeenAt,
}) => switch (state) {
  ContactActivityVisualState.typing => 'pisze…',
  ContactActivityVisualState.online => 'aktywny w aplikacji',
  ContactActivityVisualState.away => 'idle',
  ContactActivityVisualState.offline when lastSeenAt != null =>
    'ostatnio widziany ${_lastSeenLabel(lastSeenAt)}',
  ContactActivityVisualState.offline => 'offline',
  ContactActivityVisualState.unknown => 'status nieznany',
};

String _lastSeenLabel(int epochMillis) {
  final difference = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(epochMillis),
  );
  if (difference.inSeconds < 60) return 'przed chwilą';
  if (difference.inMinutes < 60) return '${difference.inMinutes} min temu';
  if (difference.inHours < 24) return '${difference.inHours} godz. temu';
  return '${difference.inDays} dni temu';
}

String identityInitial(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? '?' : normalized.characters.first.toUpperCase();
}

class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.label,
    this.radius,
    this.backgroundColor,
    this.activity,
  });

  final String label;
  final double? radius;
  final Color? backgroundColor;
  final ContactActivityVisualState? activity;

  @override
  Widget build(BuildContext context) {
    final avatar = ThemedAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      child: Text(identityInitial(label)),
    );
    final activity = this.activity;
    if (activity == null) return avatar;
    final color = switch (activity) {
      ContactActivityVisualState.typing ||
      ContactActivityVisualState.online => context.statusTheme.success,
      ContactActivityVisualState.away => context.statusTheme.warning,
      ContactActivityVisualState.offline => context.statusTheme.offline,
      ContactActivityVisualState.unknown => Theme.of(context).disabledColor,
    };
    return Tooltip(
      message: contactActivityLabel(activity),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ThemedAvatar extends StatelessWidget {
  const ThemedAvatar({
    super.key,
    required this.child,
    this.radius,
    this.backgroundColor,
  });

  final Widget child;
  final double? radius;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final diameter = (radius ?? 20) * 2;
    if (!context.effectsTheme.pixelated) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        child: child,
      );
    }
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 2,
        ),
      ),
      child: child,
    );
  }
}
