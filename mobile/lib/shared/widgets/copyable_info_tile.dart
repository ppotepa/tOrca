import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'info_tile.dart';

class CopyableInfoTile extends StatelessWidget {
  const CopyableInfoTile({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.subtitleSelectable = false,
    this.leading,
  });

  final String title;
  final String value;
  final String? subtitle;
  final bool subtitleSelectable;
  final Widget? leading;

  Future<void> _copyValue() async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  @override
  Widget build(BuildContext context) => InfoTile(
    leading: leading,
    title: title,
    subtitle: subtitle ?? value,
    subtitleSelectable: subtitleSelectable,
    trailing: IconButton(
      tooltip: 'Skopiuj',
      onPressed: value.isEmpty ? null : _copyValue,
      icon: const Icon(Icons.copy_outlined, size: 18),
    ),
    onTap: value.isEmpty ? null : _copyValue,
  );
}
