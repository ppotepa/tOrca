import 'package:flutter/material.dart';
import 'package:pixelarticons/pixelarticons.dart';

import '../extensions/torchat_effects_theme.dart';

class ThemedIcon extends StatelessWidget {
  const ThemedIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Icon(
    context.effectsTheme.pixelated ? _pixelIcon(icon) : icon,
    size: size,
    color: color,
    semanticLabel: semanticLabel,
  );
}

IconData _pixelIcon(IconData icon) => switch (icon) {
  Icons.chat_bubble_outline || Icons.chat_bubble => Pixel.chat,
  Icons.people_outline || Icons.people => Pixel.contactmultiple,
  Icons.person_outline || Icons.person => Pixel.user,
  Icons.person_add_alt_1 => Pixel.contactplus,
  Icons.settings_outlined || Icons.settings => Pixel.sliders,
  Icons.palette_outlined => Pixel.paintbucket,
  Icons.brightness_auto_outlined => Pixel.sunalt,
  Icons.eco || Icons.eco_outlined => Pixel.radiotower,
  Icons.qr_code_2 => Pixel.grid,
  Icons.search => Pixel.search,
  Icons.info_outline => Pixel.infobox,
  Icons.password => Pixel.lock,
  Icons.send || Icons.arrow_forward => Pixel.arrowright,
  Icons.arrow_back || Icons.chevron_left => Pixel.chevronleft,
  Icons.chevron_right => Pixel.chevronright,
  Icons.refresh => Pixel.reload,
  Icons.check || Icons.check_circle => Pixel.check,
  Icons.close || Icons.block_outlined => Pixel.close,
  Icons.archive_outlined => Pixel.archive,
  Icons.cancel_outlined => Pixel.closebox,
  Icons.inbox_outlined || Icons.move_to_inbox_outlined => Pixel.inbox,
  Icons.outbox_outlined => Pixel.upload,
  Icons.delete_outline => Pixel.trash,
  Icons.qr_code_scanner => Pixel.grid,
  _ => icon,
};
