// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'TorChat';

  @override
  String get languageSetupTitle => 'Choose your language';

  @override
  String get languageSetupDescription =>
      'You can change this later in Settings.';

  @override
  String get languageSystem => 'System';

  @override
  String get languagePolish => 'Polski';

  @override
  String get languageEnglish => 'English';

  @override
  String get languagePolishNative => 'Polski';

  @override
  String get languageEnglishNative => 'English';

  @override
  String get languageSettingsTitle => 'Language';

  @override
  String get languageSettingsDescription =>
      'Choose the language used by TorChat.';

  @override
  String get notificationNewMessageTitle => 'New message';

  @override
  String get notificationPairingRequestTitle => 'New contact request';

  @override
  String get notificationPrivateMessageBody => 'New encrypted message';

  @override
  String get notificationPairingRequestBody =>
      'You have a new conversation request.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsApplicationSection => 'APPLICATION';

  @override
  String get settingsFamilyTitle => 'Family';

  @override
  String get settingsFamilyDescription =>
      'Classic: standard, Retro: retro style';

  @override
  String get settingsClassic => 'Classic';

  @override
  String get settingsRetro => 'Retro';

  @override
  String get settingsTerminalPalette => 'Terminal palette';

  @override
  String get settingsBrightness => 'Brightness mode';

  @override
  String get settingsSystem => 'System';

  @override
  String get settingsLight => 'Light';

  @override
  String get settingsDark => 'Dark';

  @override
  String get settingsReduceMotion => 'Reduce animations';

  @override
  String get settingsReduceMotionDescription =>
      'Disables animations and smooth transitions throughout the app';

  @override
  String get settingsWindowsAutostart => 'Start with Windows';

  @override
  String get settingsWindowsAutostartDescription =>
      'Starts TorChat automatically after sign-in';

  @override
  String get settingsSaving => 'Saving…';

  @override
  String get settingsLastSeen => 'Last seen';

  @override
  String get settingsLastSeenDescription =>
      'Share the time of your latest activity with contacts';

  @override
  String get settingsTorConnection => 'Tor connection';

  @override
  String get settingsUserProfile => 'User profile';

  @override
  String get settingsSavingProfile => 'Saving profile…';

  @override
  String get settingsResetDemoData => 'Reset demo data';

  @override
  String get settingsRequiresConfirmation => 'Requires confirmation';

  @override
  String get settingsClearLocalState => 'Clear local state';

  @override
  String get settingsClearLocalStateDescription =>
      'Removes all test data and local entries';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsNotificationsDescription => 'Master switch for all alerts';

  @override
  String get settingsNewMessages => 'New messages';

  @override
  String get settingsNewMessagesDescription =>
      'Notify about messages outside the open conversation';

  @override
  String get settingsContactInvitations => 'Contact invitations';

  @override
  String get settingsContactInvitationsDescription =>
      'Notify only about new pairing requests';

  @override
  String get settingsNotificationSound => 'Sound';

  @override
  String get settingsNotificationSoundDescription =>
      'TorChat system notification sound';

  @override
  String get settingsNotificationVibration => 'Vibration';

  @override
  String get settingsNotificationVibrationDescription =>
      'Vibration for incoming events';

  @override
  String get settingsMessagePreview => 'Message preview';

  @override
  String get settingsMessagePreviewDescription =>
      'Disabled by default for privacy';

  @override
  String get settingsReadReceipts => 'Read receipts';

  @override
  String get settingsReadReceiptsDescription =>
      'Tell the contact that a message was read';

  @override
  String get settingsTypingIndicator => 'Typing indicator';

  @override
  String get settingsTypingIndicatorDescription =>
      'Share temporary activity while typing';

  @override
  String get settingsOnlineStatus => 'Online status';

  @override
  String get settingsOnlineStatusDescription =>
      'Share current presence without history';

  @override
  String get settingsNotificationsSection => 'NOTIFICATIONS';

  @override
  String get settingsChatPrivacySection => 'CHAT PRIVACY';

  @override
  String get settingsIdentitySection => 'IDENTITY';

  @override
  String get settingsLocalDataSection => 'LOCAL DATA';

  @override
  String get accountTitle => 'Account';

  @override
  String get accountIdentitySection => 'IDENTITY';

  @override
  String get accountLocalProfile => 'Local device profile';

  @override
  String accountInstallationId(Object id) {
    return 'Installation ID: $id';
  }

  @override
  String get accountActionsSection => 'ACTIONS';

  @override
  String get accountInviteCode => 'My invitation code';

  @override
  String get accountInviteLoading => 'Loading code…';

  @override
  String get accountInviteSubtitle => 'The code is shown in a separate window';

  @override
  String get accountSettings => 'Settings';

  @override
  String get accountSettingsSubtitle => 'Open application settings';

  @override
  String get imageCacheSection => 'IMAGES AND CACHE';

  @override
  String get imageCacheClearTitle => 'Clear image cache?';

  @override
  String get imageCacheClearDescription =>
      'Only local encrypted image copies will be removed. Messages and chat history will remain unchanged.';

  @override
  String get cancel => 'Cancel';

  @override
  String get clear => 'Clear';

  @override
  String get imageAutoDownload => 'Download images automatically';

  @override
  String get imageAutoDownloadDescription =>
      'Stores incoming images in the local AES-GCM store';

  @override
  String get encryptedCache => 'Encrypted cache';

  @override
  String get calculatingUsage => 'Calculating usage…';

  @override
  String imageFilesCount(Object count, Object size) {
    return '$count files · $size';
  }

  @override
  String get imageCacheClearing => 'Clearing…';

  @override
  String get imageCacheClearButton => 'Clear image cache';

  @override
  String get imageCacheCleared => 'Image cache was cleared.';

  @override
  String get nicknameSaving => 'Saving nickname…';

  @override
  String get nicknameReady => 'TorChat is ready';

  @override
  String get nicknameDescription =>
      'The relay and this device\'s onion service are active. Set your local username.';

  @override
  String get nicknameLabel => 'Nickname';

  @override
  String get nicknameSave => 'Save nickname';

  @override
  String get retry => 'Try again';

  @override
  String get warmupTitle => 'Warming up TorChat';

  @override
  String get warmupSubtitle => 'Private messages over Tor';

  @override
  String get communicationReady => 'Communication ready';

  @override
  String get inviteScanTitle => 'Scan pairing code';

  @override
  String get addContactTitle => 'Add contact';

  @override
  String get processingCode => 'Processing code…';

  @override
  String get desktopCodeInstructions =>
      'Desktop does not use a camera. Enter the 8-digit code shown on the other device.';

  @override
  String get pairingCodeLabel => 'Pairing code';

  @override
  String get pairingDialogTitle => 'Your pairing code';

  @override
  String get pairingRefreshing => 'Refreshing code…';

  @override
  String get pairingRefreshingAction => 'Refreshing…';

  @override
  String get pairingExpiredRefreshing => 'Code expired · refreshing…';

  @override
  String pairingValidFor(String time) {
    return 'Valid for $time';
  }

  @override
  String get pairingRefreshCode => 'Refresh code';

  @override
  String get close => 'Close';

  @override
  String get incomingPairingTitle => 'New contact request';

  @override
  String get pairingCompletedTitle => 'Contact added';

  @override
  String get pairingCompletedDescription =>
      'A secure connection was confirmed on both sides.';

  @override
  String get newContact => 'New contact';

  @override
  String get pairingSavingDecision => 'Saving decision…';

  @override
  String get pairingAcceptedDescription =>
      'The invitation was accepted. Contact finalization is running in the background.';

  @override
  String get pairingWaitingDecision =>
      'The invitation is waiting for your decision. It will not be automatically rejected by the interface timer.';

  @override
  String get securityDetails => 'Security details';

  @override
  String get contactFingerprint => 'Contact fingerprint';

  @override
  String get accepting => 'Accepting…';

  @override
  String get reject => 'Reject';

  @override
  String get accept => 'Accept';

  @override
  String get checkingInvitations => 'Checking for new invitations…';

  @override
  String get waitingForCode => 'Waiting for code use…';

  @override
  String get contactsAddTitle => 'Add contact';

  @override
  String get contactsAddDescription => 'Enter a pairing code or scan a QR code';

  @override
  String get myPairingCode => 'My pairing code';

  @override
  String get pairingCodeHint => 'Enter the 8-digit contact code';

  @override
  String get processingPairingCode => 'Processing code…';

  @override
  String get pairingCodeInputHint => 'Enter an 8-digit pairing code';

  @override
  String get sendCode => 'Send code';

  @override
  String get yourFingerprint => 'Your fingerprint';

  @override
  String yourFingerprintSemantics(String fingerprint) {
    return 'Your fingerprint: $fingerprint';
  }

  @override
  String get loadingContacts => 'Loading contacts…';

  @override
  String get contactsTitle => 'Contacts';

  @override
  String get contactDetails => 'Contact details';

  @override
  String get contactStatusActive => 'active in app';

  @override
  String get contactStatusIdle => 'idle';

  @override
  String get contactStatusOffline => 'offline';

  @override
  String get connectionCenterTitle => 'Connection center';

  @override
  String get connectionInfrastructure => 'Application infrastructure';

  @override
  String get connectionCommunicationReadiness => 'Communication readiness';

  @override
  String get connectionActivity => 'Application activity';

  @override
  String get connectionDirectSessions => 'Direct contact sessions';

  @override
  String get connectionDirectSessionsDetail =>
      'Sessions with specific contacts start after onboarding and do not block application startup.';

  @override
  String get connectionContactPresence => 'Contact presence';

  @override
  String get connectionContactPresenceDetail =>
      'Contacts reporting active presence in the runtime.';

  @override
  String get connectionLocalConversationSummaries =>
      'Local conversation summaries';

  @override
  String get connectionLocalConversationSummariesDetail =>
      'The conversation list comes from an atomic snapshot; messages load when opened.';

  @override
  String get connectionMessageQueue => 'Message queue';

  @override
  String get connectionQueueClean => 'clean';

  @override
  String connectionQueueCounts(int queued, int failed) {
    return '$queued queued · $failed failed';
  }

  @override
  String get connectionMessageQueueDetail =>
      'Messages remain in the durable queue until delivery is acknowledged.';

  @override
  String get connectionLastError => 'Last error';

  @override
  String get contactActivityTyping => 'typing…';

  @override
  String get contactActivityOnline => 'active in the app';

  @override
  String get contactActivityAway => 'idle';

  @override
  String get contactActivityUnknown => 'status unknown';

  @override
  String contactActivityLastSeen(Object label) {
    return 'last seen $label';
  }

  @override
  String get contactActivityJustNow => 'just now';

  @override
  String contactActivityMinutesAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min ago',
      one: '1 min ago',
    );
    return '$_temp0';
  }

  @override
  String contactActivityHoursAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hr ago',
      one: '1 hr ago',
    );
    return '$_temp0';
  }

  @override
  String contactActivityDaysAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get contactStatusUnknown => 'status unknown';

  @override
  String get contactStatusChecking => 'checking';

  @override
  String get routeP2P => 'P2P';

  @override
  String get routeP2PFallback => 'P2P + relay fallback';

  @override
  String get routeRelay => 'relay';

  @override
  String get messageReply => 'Reply';

  @override
  String get messageCopy => 'Copy message';

  @override
  String get messageRetry => 'Try again';

  @override
  String get messageDeleteLocal => 'Delete on this device only';

  @override
  String get messageRetrying => 'Retrying…';

  @override
  String get messageDeleting => 'Deleting…';

  @override
  String get messageStateQueued => 'queued';

  @override
  String get messageStateSending => 'sending…';

  @override
  String get messageStateSent => 'sent';

  @override
  String get messageStateDelivered => 'delivered';

  @override
  String get messageStateRead => 'read';

  @override
  String get messageStateFailed => 'send failed';

  @override
  String get chatStarting => 'Starting conversation…';

  @override
  String get chatLoading => 'Loading conversation…';

  @override
  String get chatBack => 'Back';

  @override
  String get chatSearchHint => 'Search this conversation…';

  @override
  String get chatContactViewing => 'Contact is viewing this conversation';

  @override
  String get chatCloseSearch => 'Close search';

  @override
  String get chatSearch => 'Search';

  @override
  String get chatOptions => 'Conversation options';

  @override
  String get chatCopyFingerprint => 'Copy fingerprint';

  @override
  String get chatLoadingOlder => 'Loading older messages…';

  @override
  String chatUnseenMessages(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count new messages',
      one: '1 new message',
      zero: 'No new messages',
    );
    return '$_temp0';
  }

  @override
  String get chatScrollToBottom => 'Scroll to bottom';

  @override
  String get chatPrivateCommunication => 'Private communication through Tor';

  @override
  String chatCounts(int contacts, int conversations) {
    return '$contacts contacts · $conversations conversations';
  }

  @override
  String get chatRecentConversations => 'Recent conversations';

  @override
  String get chatVerifyContact =>
      'Verify the contact\'s identity in the details to start a conversation.';

  @override
  String chatConversationStarted(String name) {
    return 'This is the beginning of your conversation with $name.';
  }

  @override
  String get chatSecureConnectionStarting => 'Establishing a secure connection';

  @override
  String get chatWaitingForSecureConnection =>
      'The conversation is waiting for a secure connection.';

  @override
  String get chatRemoveAttachment => 'Remove attachment';

  @override
  String get chatCancelReply => 'Cancel reply';

  @override
  String get chatPreparingImages => 'Preparing images…';

  @override
  String get chatAddImages => 'Add images to message';

  @override
  String get chatComposeHint => 'Write a message…';

  @override
  String get chatNotReady => 'Conversation is not ready yet';

  @override
  String get statusTransportConnected => 'Connected to relay through Tor';

  @override
  String get statusTransportStarting => 'Starting Tor';

  @override
  String get statusTransportBootstrapping => 'Bootstrapping Tor circuit';

  @override
  String get statusTransportConnecting => 'Connecting to onion relay';

  @override
  String get statusTransportDegraded => 'Relay is operating in limited mode';

  @override
  String get statusTransportReconnecting => 'Reconnecting to relay';

  @override
  String get statusTransportOffline => 'Tor offline';

  @override
  String get statusTransportError => 'Checking Tor connection';

  @override
  String get statusComponentEngine => 'Application engine';

  @override
  String get statusComponentLocalData => 'Local data';

  @override
  String get statusComponentTor => 'Tor network';

  @override
  String get statusComponentRelay => 'TorChat relay';

  @override
  String get statusComponentPeerListener => 'Local P2P listener';

  @override
  String get statusComponentOnionService => 'This device\'s onion service';

  @override
  String get statusComponentEngineDescription => 'Shared messenger engine';

  @override
  String get statusComponentLocalDataDescription =>
      'Identity and encrypted local database';

  @override
  String get statusComponentTorDescription =>
      'Tor process and local SOCKS endpoint';

  @override
  String get statusComponentRelayDescription =>
      'Control connection to the onion relay';

  @override
  String get statusComponentPeerListenerDescription =>
      'Local server accepting peer connections';

  @override
  String get statusComponentOnionServiceDescription =>
      'Onion address published for this device';

  @override
  String get desktopChats => 'Chats';

  @override
  String desktopConversationCount(int count) {
    return '$count conversations';
  }

  @override
  String get desktopSearch => 'Search…';

  @override
  String get desktopNoConversations => 'You have no conversations yet.';

  @override
  String get desktopNoConversationMatches =>
      'No conversations match your search.';

  @override
  String get desktopContacts => 'Contacts';

  @override
  String get desktopFilteredContactsEmpty =>
      'No contacts match the selected filter.';

  @override
  String desktopContactCount(int count) {
    return '$count saved';
  }

  @override
  String get desktopSearchContacts => 'Search contacts…';

  @override
  String get desktopAll => 'All';

  @override
  String get desktopOnline => 'Online';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonNo => 'No';

  @override
  String get desktopContactDetails => 'Contact details';

  @override
  String get desktopCloseDetails => 'Close details';

  @override
  String get desktopContactSection => 'CONTACT';

  @override
  String get desktopIdentityVerified => 'Identity verified';

  @override
  String get desktopIdentityUnverified => 'Identity not verified';

  @override
  String get desktopVerifyIdentity => 'Verify identity';

  @override
  String get desktopPresenceSection => 'PRESENCE';

  @override
  String get desktopStatus => 'Status';

  @override
  String get desktopLastSeen => 'Last seen';

  @override
  String get desktopObserved => 'Observed';

  @override
  String get desktopObservationExpiry => 'Observation expiry';

  @override
  String get desktopConversationFocus => 'Conversation focus';

  @override
  String get desktopConnectionSection => 'CONNECTION';

  @override
  String get desktopP2pConnection => 'P2P connection';

  @override
  String get desktopProbeLatency => 'Probe latency';

  @override
  String get desktopNextProbe => 'Next probe';

  @override
  String get desktopLastP2pConnection => 'Last P2P connection';

  @override
  String get desktopRoute => 'Route';

  @override
  String get desktopEndpoint => 'Endpoint';

  @override
  String get desktopPolicy => 'Policy';

  @override
  String get desktopInformationSection => 'INFORMATION';

  @override
  String get desktopInstallationId => 'Installation ID';

  @override
  String get desktopLastP2p => 'Last P2P';

  @override
  String get desktopBackToConversations => 'Back to conversation list';

  @override
  String get statusProbeEngine => 'Engine';

  @override
  String get statusProbeRelay => 'Tor relay';

  @override
  String get statusProbePeer => 'Tor P2P';

  @override
  String get startupEngine => 'Shared engine';

  @override
  String get startupLocalData => 'Local data';

  @override
  String get startupTor => 'Tor network';

  @override
  String get startupPeerListener => 'Local P2P server';

  @override
  String get startupOnionService => 'P2P onion service';

  @override
  String get startupRelay => 'Tor relay';

  @override
  String get startupCommunication => 'Communication readiness';

  @override
  String get startupEngineDescription => 'Starting shared Rust engine';

  @override
  String get startupLocalDataDescription =>
      'Opening encrypted database and identity';

  @override
  String get startupTorDescription => 'Starting Tor and preparing SOCKS';

  @override
  String get startupPeerListenerDescription =>
      'Listening on the local peer server';

  @override
  String get startupOnionServiceDescription =>
      'Publishing this device\'s onion address';

  @override
  String get startupRelayDescription => 'Connecting to the control server';

  @override
  String get startupCommunicationDescription => 'Message queues and receiving';

  @override
  String contactSemantics(String name) {
    return 'Contact $name';
  }

  @override
  String get contactSemanticsHint =>
      'Tap to start a conversation. Hold to open the menu.';

  @override
  String get contactStartConversation => 'Start conversation';

  @override
  String get contactEnableNotifications => 'Enable notifications';

  @override
  String get contactMute => 'Mute contact';

  @override
  String get contactCopyFingerprint => 'Copy fingerprint';

  @override
  String get contactEndRelationship => 'End relationship';

  @override
  String get conversationsLoading => 'Loading conversations…';

  @override
  String get conversationRename => 'Rename locally';

  @override
  String get conversationUnpin => 'Unpin';

  @override
  String get conversationPin => 'Pin';

  @override
  String get conversationEnableNotifications => 'Enable notifications';

  @override
  String get conversationMute => 'Mute';

  @override
  String get conversationClearHistory => 'Clear local history';

  @override
  String get conversationArchive => 'Archive locally';

  @override
  String get conversationLocalName => 'Local conversation name';

  @override
  String get conversationName => 'Name';

  @override
  String get conversationNameLocalOnly => 'This name stays on this device.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCopy => 'Copy';

  @override
  String get conversationRestore => 'Restore';

  @override
  String get conversationClearHistoryTitle => 'Clear local history?';

  @override
  String get conversationClearHistoryDescription =>
      'Messages will be deleted only from this device. The contact will not be notified.';

  @override
  String get conversationClear => 'Clear';

  @override
  String get conversationHistoryCleared => 'Local history cleared.';

  @override
  String get problemPairingWelcomeStale =>
      'This invitation can no longer be completed. Ask the contact to generate a new pairing code.';

  @override
  String get problemPairingCodeInvalid =>
      'The pairing code is invalid or expired. Ask the contact for a new code.';

  @override
  String get problemPairingRequiresRelay =>
      'Pairing requires an available relay; local data remains available offline.';

  @override
  String get problemNicknameRequired => 'Set a username on this device first.';

  @override
  String get problemInviteCodeUnavailable =>
      'The relay did not return an invitation code. Try again.';

  @override
  String get problemPairingGatewayUnavailable =>
      'The pairing service is temporarily unavailable. Try again shortly.';

  @override
  String get problemSecureConnectionPending =>
      'The secure connection is not ready yet.';

  @override
  String get problemConnectionUnavailable =>
      'The connection is temporarily unavailable.';

  @override
  String get problemOperationFailed => 'The operation could not be completed.';

  @override
  String get paletteArcade => 'Arcade';

  @override
  String get paletteMocha => 'Mocha';

  @override
  String get paletteGruvbox => 'Gruvbox';

  @override
  String get paletteNord => 'Nord';

  @override
  String get shellAccount => 'Account';

  @override
  String get shellSettings => 'Settings';

  @override
  String get contactsLocalAlias => 'Local alias';

  @override
  String get contactsSaving => 'Saving…';

  @override
  String get commonClose => 'Close';

  @override
  String get relationshipEndTitle => 'End relationship?';

  @override
  String relationshipEndDescription(String name) {
    return 'Contact $name will no longer be able to send messages. Adding them again will require a new code.';
  }

  @override
  String get relationshipKeepHistory => 'Keep history on this device';

  @override
  String get relationshipKeepHistoryDescription =>
      'History remains local and will not restore the relationship.';

  @override
  String get imageDownload => 'Download image';

  @override
  String get imageSaveToGallery => 'Save to gallery';

  @override
  String get imageRemoveFromCache => 'Remove from encrypted cache';

  @override
  String get commonRetry => 'Try again';

  @override
  String get commonDeleteLocal => 'Delete on this device only';

  @override
  String get connectionDiagnosticsCopied => 'Diagnostics copied.';

  @override
  String get connectionCopyDiagnostics => 'Copy diagnostics';

  @override
  String get connectionRetry => 'Retry connection';

  @override
  String get connectionRetrying => 'Retrying…';

  @override
  String get commonContact => 'Contact';

  @override
  String get commonImage => 'Image';

  @override
  String get chatWaitingForMessage => 'Waiting for a message';

  @override
  String get contactsRotate => 'Rotate';

  @override
  String get contactsRevoke => 'Revoke';

  @override
  String get contactsNoDeadLetters => 'No dead letters';

  @override
  String get contactsDeadLetterRetry => 'Dead-letter retry';

  @override
  String get contactsNoError => 'No error';

  @override
  String get contactsSavingSettings => 'Saving settings…';

  @override
  String get contactsEstablishedByPairingCode =>
      'Relationship established by accepted code';

  @override
  String get contactsP2pThroughTor => 'P2P through Tor';

  @override
  String get contactsDirectConnection => 'Direct connection';

  @override
  String get contactsCurrentRoute => 'Current route';

  @override
  String get contactsPresence => 'Presence';

  @override
  String get contactsViewingConversation => 'Viewing conversation';

  @override
  String get contactsLastProbe => 'Last probe';

  @override
  String get contactsNoData => 'no data';

  @override
  String get contactsProbeLatency => 'Probe latency';

  @override
  String get contactsP2pCapability => 'P2P endpoint capability';

  @override
  String get contactsCapabilityUnavailable => 'Capability status unavailable';

  @override
  String get contactRouteRelay => 'relay';

  @override
  String get contactRouteP2pOnion => 'P2P onion';

  @override
  String get contactRouteRelayFallback => 'live relay fallback (P2P inactive)';

  @override
  String get contactRouteP2pOffline => 'P2P waiting / offline';

  @override
  String get contactEndpointVerified => 'endpoint verified';

  @override
  String get contactEndpointPending => 'waiting for endpoint exchange';

  @override
  String get contactEndpointInvalid => 'invalid endpoint';

  @override
  String get contactEndpointMissing => 'endpoint unavailable';

  @override
  String get contactAvailabilityActive => 'active in app';

  @override
  String get contactAvailabilityIdle => 'idle';

  @override
  String get contactAvailabilityChecking => 'checking';

  @override
  String get contactAvailabilityOffline => 'offline';

  @override
  String get contactAvailabilityUnknown => 'unknown status';

  @override
  String get contactPeerConnected => 'connected';

  @override
  String get contactPeerConnecting => 'connecting';

  @override
  String get contactPeerAuthenticating => 'authenticating';

  @override
  String get contactPeerBackoff => 'waiting to retry';

  @override
  String get contactPeerOffline => 'offline';

  @override
  String get contactPeerUnknown => 'unknown';

  @override
  String get contactPolicyP2pOnly => 'P2P only';

  @override
  String get contactPolicyFallback => 'P2P + live relay fallback';

  @override
  String get contactsNewContact => 'New contact';

  @override
  String get contactsWaitingForSecureConversation =>
      'Waiting to establish a secure conversation';

  @override
  String get contactsTransportPolicy => 'Transport policy';

  @override
  String get onboardingNicknameLabel => 'Nickname';

  @override
  String get onboardingSaveNickname => 'Save nickname';

  @override
  String get appTagline => 'Private messages through Tor';

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String timeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }
}
