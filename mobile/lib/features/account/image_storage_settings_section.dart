import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../core/attachments/encrypted_image_store.dart';
import '../../shared/widgets/action_section.dart';
import '../../shared/widgets/info_tile.dart';
import '../../shared/widgets/themed_switch_list_tile.dart';
import '../../locales/presentation/app_localizations_x.dart';

class ImageStorageSettingsSection extends ConsumerStatefulWidget {
  const ImageStorageSettingsSection({super.key});

  @override
  ConsumerState<ImageStorageSettingsSection> createState() =>
      _ImageStorageSettingsSectionState();
}

class _ImageStorageSettingsSectionState
    extends ConsumerState<ImageStorageSettingsSection> {
  bool _automaticDownload = false;
  bool _loading = true;
  bool _saving = false;
  bool _clearing = false;
  ImageCacheUsage _usage = const ImageCacheUsage(files: 0, bytes: 0);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final automatic =
          await ImageAttachmentPreferences.automaticDownloadEnabled();
      final usage = await EncryptedImageStore.instance.usage();
      if (!mounted) return;
      setState(() {
        _automaticDownload = automatic;
        _usage = usage;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(context.l10n.uiImageCacheLoadFailed, 'load');
    }
  }

  Future<void> _setAutomaticDownload(bool value) async {
    if (_saving) return;
    final previous = _automaticDownload;
    setState(() {
      _automaticDownload = value;
      _saving = true;
    });
    try {
      await ImageAttachmentPreferences.setAutomaticDownloadEnabled(value);
    } catch (_) {
      if (mounted) {
        setState(() => _automaticDownload = previous);
        _showError(context.l10n.uiImagePreferenceSaveFailed, 'preference');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearCache() async {
    if (_clearing || _usage.files == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.imageCacheClearTitle),
        content: Text(context.l10n.imageCacheClearDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await EncryptedImageStore.instance.clear();
      final usage = await EncryptedImageStore.instance.usage();
      if (!mounted) return;
      setState(() => _usage = usage);
      ref
          .read(uiNotificationCenterProvider.notifier)
          .showSuccess(
            context.l10n.imageCacheCleared,
            deduplicationKey: 'image-cache-cleared',
          );
    } catch (_) {
      if (mounted) {
        _showError(context.l10n.uiImageCacheClearFailed, 'clear');
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  void _showError(String message, String operation) {
    ref
        .read(uiNotificationCenterProvider.notifier)
        .showError(
          message,
          deduplicationKey: 'image-cache-error:$operation',
        );
  }

  @override
  Widget build(BuildContext context) => ActionSection(
    title: context.l10n.imageCacheSection,
    child: Column(
      children: [
        ThemedSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.imageAutoDownload),
          subtitle: Text(context.l10n.imageAutoDownloadDescription),
          value: _automaticDownload,
          onChanged: _loading || _saving ? null : _setAutomaticDownload,
        ),
        const Divider(),
        InfoTile(
          leading: const ThemedIcon(Icons.lock_outline),
          title: context.l10n.encryptedCache,
          subtitle: _loading
              ? context.l10n.calculatingUsage
              : context.l10n.imageFilesCount(
                  _usage.files,
                  _usage.formattedBytes,
                ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _loading || _clearing || _usage.files == 0
                ? null
                : _clearCache,
            icon: _clearing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const ThemedIcon(Icons.delete_sweep_outlined),
            label: Text(
              _clearing
                  ? context.l10n.imageCacheClearing
                  : context.l10n.imageCacheClearButton,
            ),
          ),
        ),
      ],
    ),
  );
}
