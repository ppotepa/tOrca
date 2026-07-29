import 'package:flutter/material.dart';

import 'copyable_info_tile.dart';
import 'profile_summary.dart';
import 'section_card.dart';

class IdentitySection extends StatelessWidget {
  const IdentitySection({
    super.key,
    required this.title,
    required this.name,
    required this.subtitle,
    required this.fingerprint,
    this.fingerprintLabel = 'Fingerprint',
    this.selectableFingerprint = false,
  });

  final String title;
  final String name;
  final String subtitle;
  final String fingerprint;
  final String fingerprintLabel;
  final bool selectableFingerprint;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProfileSummary(name: name, subtitle: subtitle),
        const SizedBox(height: 12),
        CopyableInfoTile(
          title: fingerprintLabel,
          value: fingerprint,
          subtitleSelectable: selectableFingerprint,
        ),
      ],
    ),
  );
}
