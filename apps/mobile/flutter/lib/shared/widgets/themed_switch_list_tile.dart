import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/app_theme.dart';

class ThemedSwitchListTile extends StatelessWidget {
  const ThemedSwitchListTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.contentPadding = EdgeInsets.zero,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    if (!context.effectsTheme.pixelated) {
      return SwitchListTile(
        contentPadding: contentPadding,
        title: title,
        subtitle: subtitle,
        value: value,
        onChanged: onChanged,
      );
    }

    final enabled = onChanged != null;
    return Semantics(
      button: true,
      toggled: value,
      enabled: enabled,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        customBorder: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        child: Padding(
          padding: contentPadding.add(const EdgeInsets.symmetric(vertical: 10)),
          child: Opacity(
            opacity: enabled ? 1 : .45,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle.merge(
                        style: Theme.of(context).textTheme.bodyLarge,
                        child: title,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: Theme.of(context).textTheme.bodySmall,
                          child: subtitle!,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _PixelSwitch(value: value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PixelSwitch extends StatelessWidget {
  const _PixelSwitch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final status = context.statusTheme;
    final active = status.success;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: 48,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? active.withValues(alpha: .24) : shell.raisedSurface,
        border: Border.all(
          color: value ? active : shell.border,
          width: shell.borderWidth.clamp(2, 3),
        ),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 90),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 14,
          child: ColoredBox(color: value ? active : shell.navigationForeground),
        ),
      ),
    );
  }
}
