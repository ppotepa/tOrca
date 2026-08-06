part of 'torca_app.dart';

extension _ApplicationDialogs on _ControllerHomePageState {
  Future<void> _showIncomingPairingPrompt(PairingItem request) async {
    if (!mounted || _pairingUi.codeSurfaceOpen) {
      _pairingUi.unschedule(request.id);
      return;
    }
    _pairingUi.beginIncoming(request.id);
    final controller = ref.read(appControllerProvider.notifier);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => IncomingPairingDialog(
          request: request,
          onAccept: () async {
            await controller.acceptPairing(request.id);
            _pairingUi.beginProcessing();
            _pairingUi.resolve(request.id);
            await controller.refreshData();
          },
          onReject: () async {
            await controller.rejectPairing(request.id);
            _pairingUi.beginProcessing();
            _pairingUi.resolve(request.id);
            await controller.refreshData();
          },
        ),
      );
    } finally {
      _pairingUi.closeSurface();
      if (mounted) {
        _queueIncomingPairingPrompt(ref.read(appControllerProvider).inbox);
      }
    }
  }

  Future<void> _showInvite() async {
    if (_pairingUi.codeSurfaceOpen || _pairingUi.incomingSurfaceOpen) return;
    _pairingUi.beginCodeSurface();
    final controller = ref.read(appControllerProvider.notifier);
    try {
      await showDialog<bool>(
        context: context,
        builder: (_) => PairingCodeDialog(
          initialCode: '',
          initialExpiresAt: 0,
          refresh: () => controller.refreshInviteCode(quietWhenPending: true),
          onChanged: (_) {},
          checkRequest: () async {
            await controller.refreshData();
            return ref
                .read(appControllerProvider)
                .inbox
                .firstOrNullWhere(
                  (item) =>
                      item.requiresLocalDecision &&
                      !_pairingUi.isResolved(item.id),
                );
          },
          onAccept: (request) async {
            await controller.acceptPairing(request.id);
            _pairingUi.resolve(request.id);
            await controller.refreshData();
            return true;
          },
          onReject: (request) async {
            await controller.rejectPairing(request.id);
            _pairingUi.resolve(request.id);
            await controller.refreshData();
          },
        ),
      );
    } finally {
      _pairingUi.endCodeSurface();
      if (mounted) {
        await controller.refreshData();
        _queueIncomingPairingPrompt(ref.read(appControllerProvider).inbox);
      }
    }
  }

  Future<void> _showTransportStatus() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const ConnectionCenterSheet(),
  );

  Future<void> _scanInvite() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const InviteScannerPage()),
    );
    if (!mounted || value == null) return;
    await ref.read(appControllerProvider.notifier).submitPairingCode(value);
  }

  void _openAccount() {
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    final profile = snapshot?.profile ?? const RuntimeProfile();
    final identity = snapshot?.identity ?? const RuntimeIdentity();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountView(
          nickname: profile.nickname,
          installationId: identity.installationId,
          fingerprint: profile.fingerprint,
          onShowInvite: () {
            Navigator.pop(context);
            _showInvite();
          },
          onOpenSettings: () {
            Navigator.pop(context);
            _openSettings();
          },
        ),
      ),
    );
  }

  void _openSettings() {
    final state = ref.read(appControllerProvider);
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsView(
          nickname: snapshot?.profile.nickname ?? state.profile.nickname,
          themePreferences:
              ref.read(themeControllerProvider).valueOrNull ??
              const TorChatThemePreferences(),
          onThemeFamilyChanged: (family) {
            unawaited(
              ref.read(themeControllerProvider.notifier).setFamily(family),
            );
          },
          onBrightnessChanged: (brightness) {
            unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .setBrightness(brightness),
            );
          },
          onRetroPaletteChanged: (palette) {
            unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .setRetroPalette(palette),
            );
          },
          onOpenTor: () {
            Navigator.pop(context);
            _showTransportStatus();
          },
          onEditProfile: () {
            Navigator.pop(context);
            _editNickname();
          },
          onReset: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(_l10n.settingsResetDemoData),
              content: Text(_l10n.uiResetLocalStateInstructions),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_l10n.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editNickname() async {
    final appController = ref.read(appControllerProvider.notifier);
    final state = ref.read(appControllerProvider);
    final snapshot = ref.read(applicationSnapshotProvider).valueOrNull;
    final field = TextEditingController(
      text: snapshot?.profile.nickname ?? state.profile.nickname,
    );
    final nickname = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_l10n.uiEditNickname),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 32,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: _l10n.nicknameLabel),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: Text(_l10n.commonSave),
          ),
        ],
      ),
    );
    field.dispose();
    if (nickname != null && nickname.trim().isNotEmpty) {
      await appController.setNickname(nickname);
    }
  }
}
