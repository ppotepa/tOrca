import '../../app/theme/theme_preferences.dart';
import '../generated/app_localizations.dart';

String localizeRetroPalette(
  AppLocalizations l10n,
  TorChatRetroPalette palette,
) => switch (palette) {
  TorChatRetroPalette.arcade => l10n.paletteArcade,
  TorChatRetroPalette.mocha => l10n.paletteMocha,
  TorChatRetroPalette.gruvbox => l10n.paletteGruvbox,
  TorChatRetroPalette.nord => l10n.paletteNord,
};
