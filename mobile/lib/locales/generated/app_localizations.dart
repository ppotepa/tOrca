import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pl.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pl'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'TorChat'**
  String get appTitle;

  /// No description provided for @languageSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose your language'**
  String get languageSetupTitle;

  /// No description provided for @languageSetupDescription.
  ///
  /// In en, this message translates to:
  /// **'You can change this later in Settings.'**
  String get languageSetupDescription;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @languagePolish.
  ///
  /// In en, this message translates to:
  /// **'Polski'**
  String get languagePolish;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languagePolishNative.
  ///
  /// In en, this message translates to:
  /// **'Polski'**
  String get languagePolishNative;

  /// No description provided for @languageEnglishNative.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglishNative;

  /// No description provided for @languageSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSettingsTitle;

  /// No description provided for @languageSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose the language used by TorChat.'**
  String get languageSettingsDescription;

  /// No description provided for @notificationNewMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get notificationNewMessageTitle;

  /// No description provided for @notificationPairingRequestTitle.
  ///
  /// In en, this message translates to:
  /// **'New contact request'**
  String get notificationPairingRequestTitle;

  /// No description provided for @notificationPrivateMessageBody.
  ///
  /// In en, this message translates to:
  /// **'New encrypted message'**
  String get notificationPrivateMessageBody;

  /// No description provided for @notificationPairingRequestBody.
  ///
  /// In en, this message translates to:
  /// **'You have a new conversation request.'**
  String get notificationPairingRequestBody;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsApplicationSection.
  ///
  /// In en, this message translates to:
  /// **'APPLICATION'**
  String get settingsApplicationSection;

  /// No description provided for @settingsFamilyTitle.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get settingsFamilyTitle;

  /// No description provided for @settingsFamilyDescription.
  ///
  /// In en, this message translates to:
  /// **'Classic: standard, Retro: retro style'**
  String get settingsFamilyDescription;

  /// No description provided for @settingsClassic.
  ///
  /// In en, this message translates to:
  /// **'Classic'**
  String get settingsClassic;

  /// No description provided for @settingsRetro.
  ///
  /// In en, this message translates to:
  /// **'Retro'**
  String get settingsRetro;

  /// No description provided for @settingsTerminalPalette.
  ///
  /// In en, this message translates to:
  /// **'Terminal palette'**
  String get settingsTerminalPalette;

  /// No description provided for @settingsBrightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness mode'**
  String get settingsBrightness;

  /// No description provided for @settingsSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsSystem;

  /// No description provided for @settingsLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsLight;

  /// No description provided for @settingsDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsDark;

  /// No description provided for @settingsReduceMotion.
  ///
  /// In en, this message translates to:
  /// **'Reduce animations'**
  String get settingsReduceMotion;

  /// No description provided for @settingsReduceMotionDescription.
  ///
  /// In en, this message translates to:
  /// **'Disables animations and smooth transitions throughout the app'**
  String get settingsReduceMotionDescription;

  /// No description provided for @settingsWindowsAutostart.
  ///
  /// In en, this message translates to:
  /// **'Start with Windows'**
  String get settingsWindowsAutostart;

  /// No description provided for @settingsWindowsAutostartDescription.
  ///
  /// In en, this message translates to:
  /// **'Starts TorChat automatically after sign-in'**
  String get settingsWindowsAutostartDescription;

  /// No description provided for @settingsSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get settingsSaving;

  /// No description provided for @settingsLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last seen'**
  String get settingsLastSeen;

  /// No description provided for @settingsLastSeenDescription.
  ///
  /// In en, this message translates to:
  /// **'Share the time of your latest activity with contacts'**
  String get settingsLastSeenDescription;

  /// No description provided for @settingsTorConnection.
  ///
  /// In en, this message translates to:
  /// **'Tor connection'**
  String get settingsTorConnection;

  /// No description provided for @settingsUserProfile.
  ///
  /// In en, this message translates to:
  /// **'User profile'**
  String get settingsUserProfile;

  /// No description provided for @settingsSavingProfile.
  ///
  /// In en, this message translates to:
  /// **'Saving profile…'**
  String get settingsSavingProfile;

  /// No description provided for @settingsResetDemoData.
  ///
  /// In en, this message translates to:
  /// **'Reset demo data'**
  String get settingsResetDemoData;

  /// No description provided for @settingsRequiresConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Requires confirmation'**
  String get settingsRequiresConfirmation;

  /// No description provided for @settingsClearLocalState.
  ///
  /// In en, this message translates to:
  /// **'Clear local state'**
  String get settingsClearLocalState;

  /// No description provided for @settingsClearLocalStateDescription.
  ///
  /// In en, this message translates to:
  /// **'Removes all test data and local entries'**
  String get settingsClearLocalStateDescription;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsNotificationsDescription.
  ///
  /// In en, this message translates to:
  /// **'Master switch for all alerts'**
  String get settingsNotificationsDescription;

  /// No description provided for @settingsNewMessages.
  ///
  /// In en, this message translates to:
  /// **'New messages'**
  String get settingsNewMessages;

  /// No description provided for @settingsNewMessagesDescription.
  ///
  /// In en, this message translates to:
  /// **'Notify about messages outside the open conversation'**
  String get settingsNewMessagesDescription;

  /// No description provided for @settingsContactInvitations.
  ///
  /// In en, this message translates to:
  /// **'Contact invitations'**
  String get settingsContactInvitations;

  /// No description provided for @settingsContactInvitationsDescription.
  ///
  /// In en, this message translates to:
  /// **'Notify only about new pairing requests'**
  String get settingsContactInvitationsDescription;

  /// No description provided for @settingsNotificationSound.
  ///
  /// In en, this message translates to:
  /// **'Sound'**
  String get settingsNotificationSound;

  /// No description provided for @settingsNotificationSoundDescription.
  ///
  /// In en, this message translates to:
  /// **'TorChat system notification sound'**
  String get settingsNotificationSoundDescription;

  /// No description provided for @settingsNotificationVibration.
  ///
  /// In en, this message translates to:
  /// **'Vibration'**
  String get settingsNotificationVibration;

  /// No description provided for @settingsNotificationVibrationDescription.
  ///
  /// In en, this message translates to:
  /// **'Vibration for incoming events'**
  String get settingsNotificationVibrationDescription;

  /// No description provided for @settingsMessagePreview.
  ///
  /// In en, this message translates to:
  /// **'Message preview'**
  String get settingsMessagePreview;

  /// No description provided for @settingsMessagePreviewDescription.
  ///
  /// In en, this message translates to:
  /// **'Disabled by default for privacy'**
  String get settingsMessagePreviewDescription;

  /// No description provided for @settingsReadReceipts.
  ///
  /// In en, this message translates to:
  /// **'Read receipts'**
  String get settingsReadReceipts;

  /// No description provided for @settingsReadReceiptsDescription.
  ///
  /// In en, this message translates to:
  /// **'Tell the contact that a message was read'**
  String get settingsReadReceiptsDescription;

  /// No description provided for @settingsTypingIndicator.
  ///
  /// In en, this message translates to:
  /// **'Typing indicator'**
  String get settingsTypingIndicator;

  /// No description provided for @settingsTypingIndicatorDescription.
  ///
  /// In en, this message translates to:
  /// **'Share temporary activity while typing'**
  String get settingsTypingIndicatorDescription;

  /// No description provided for @settingsOnlineStatus.
  ///
  /// In en, this message translates to:
  /// **'Online status'**
  String get settingsOnlineStatus;

  /// No description provided for @settingsOnlineStatusDescription.
  ///
  /// In en, this message translates to:
  /// **'Share current presence without history'**
  String get settingsOnlineStatusDescription;

  /// No description provided for @settingsNotificationsSection.
  ///
  /// In en, this message translates to:
  /// **'NOTIFICATIONS'**
  String get settingsNotificationsSection;

  /// No description provided for @settingsChatPrivacySection.
  ///
  /// In en, this message translates to:
  /// **'CHAT PRIVACY'**
  String get settingsChatPrivacySection;

  /// No description provided for @settingsIdentitySection.
  ///
  /// In en, this message translates to:
  /// **'IDENTITY'**
  String get settingsIdentitySection;

  /// No description provided for @settingsLocalDataSection.
  ///
  /// In en, this message translates to:
  /// **'LOCAL DATA'**
  String get settingsLocalDataSection;

  /// No description provided for @accountTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountTitle;

  /// No description provided for @accountIdentitySection.
  ///
  /// In en, this message translates to:
  /// **'IDENTITY'**
  String get accountIdentitySection;

  /// No description provided for @accountLocalProfile.
  ///
  /// In en, this message translates to:
  /// **'Local device profile'**
  String get accountLocalProfile;

  /// No description provided for @accountInstallationId.
  ///
  /// In en, this message translates to:
  /// **'Installation ID: {id}'**
  String accountInstallationId(Object id);

  /// No description provided for @accountActionsSection.
  ///
  /// In en, this message translates to:
  /// **'ACTIONS'**
  String get accountActionsSection;

  /// No description provided for @accountInviteCode.
  ///
  /// In en, this message translates to:
  /// **'My invitation code'**
  String get accountInviteCode;

  /// No description provided for @accountInviteLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading code…'**
  String get accountInviteLoading;

  /// No description provided for @accountInviteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The code is shown in a separate window'**
  String get accountInviteSubtitle;

  /// No description provided for @accountSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get accountSettings;

  /// No description provided for @accountSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open application settings'**
  String get accountSettingsSubtitle;

  /// No description provided for @imageCacheSection.
  ///
  /// In en, this message translates to:
  /// **'IMAGES AND CACHE'**
  String get imageCacheSection;

  /// No description provided for @imageCacheClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear image cache?'**
  String get imageCacheClearTitle;

  /// No description provided for @imageCacheClearDescription.
  ///
  /// In en, this message translates to:
  /// **'Only local encrypted image copies will be removed. Messages and chat history will remain unchanged.'**
  String get imageCacheClearDescription;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @imageAutoDownload.
  ///
  /// In en, this message translates to:
  /// **'Download images automatically'**
  String get imageAutoDownload;

  /// No description provided for @imageAutoDownloadDescription.
  ///
  /// In en, this message translates to:
  /// **'Stores incoming images in the local AES-GCM store'**
  String get imageAutoDownloadDescription;

  /// No description provided for @encryptedCache.
  ///
  /// In en, this message translates to:
  /// **'Encrypted cache'**
  String get encryptedCache;

  /// No description provided for @calculatingUsage.
  ///
  /// In en, this message translates to:
  /// **'Calculating usage…'**
  String get calculatingUsage;

  /// No description provided for @imageFilesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} files · {size}'**
  String imageFilesCount(Object count, Object size);

  /// No description provided for @imageCacheClearing.
  ///
  /// In en, this message translates to:
  /// **'Clearing…'**
  String get imageCacheClearing;

  /// No description provided for @imageCacheClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear image cache'**
  String get imageCacheClearButton;

  /// No description provided for @imageCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Image cache was cleared.'**
  String get imageCacheCleared;

  /// No description provided for @nicknameSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving nickname…'**
  String get nicknameSaving;

  /// No description provided for @nicknameReady.
  ///
  /// In en, this message translates to:
  /// **'TorChat is ready'**
  String get nicknameReady;

  /// No description provided for @nicknameDescription.
  ///
  /// In en, this message translates to:
  /// **'The relay and this device\'s onion service are active. Set your local username.'**
  String get nicknameDescription;

  /// No description provided for @nicknameLabel.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nicknameLabel;

  /// No description provided for @nicknameSave.
  ///
  /// In en, this message translates to:
  /// **'Save nickname'**
  String get nicknameSave;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// No description provided for @warmupTitle.
  ///
  /// In en, this message translates to:
  /// **'Warming up TorChat'**
  String get warmupTitle;

  /// No description provided for @warmupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Private messages over Tor'**
  String get warmupSubtitle;

  /// No description provided for @communicationReady.
  ///
  /// In en, this message translates to:
  /// **'Communication ready'**
  String get communicationReady;

  /// No description provided for @inviteScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan pairing code'**
  String get inviteScanTitle;

  /// No description provided for @addContactTitle.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get addContactTitle;

  /// No description provided for @processingCode.
  ///
  /// In en, this message translates to:
  /// **'Processing code…'**
  String get processingCode;

  /// No description provided for @desktopCodeInstructions.
  ///
  /// In en, this message translates to:
  /// **'Desktop does not use a camera. Enter the 8-digit code shown on the other device.'**
  String get desktopCodeInstructions;

  /// No description provided for @pairingCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Pairing code'**
  String get pairingCodeLabel;

  /// No description provided for @pairingDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Your pairing code'**
  String get pairingDialogTitle;

  /// No description provided for @pairingRefreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing code…'**
  String get pairingRefreshing;

  /// No description provided for @pairingRefreshingAction.
  ///
  /// In en, this message translates to:
  /// **'Refreshing…'**
  String get pairingRefreshingAction;

  /// No description provided for @pairingExpiredRefreshing.
  ///
  /// In en, this message translates to:
  /// **'Code expired · refreshing…'**
  String get pairingExpiredRefreshing;

  /// Remaining validity of a pairing code
  ///
  /// In en, this message translates to:
  /// **'Valid for {time}'**
  String pairingValidFor(String time);

  /// No description provided for @pairingRefreshCode.
  ///
  /// In en, this message translates to:
  /// **'Refresh code'**
  String get pairingRefreshCode;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @incomingPairingTitle.
  ///
  /// In en, this message translates to:
  /// **'New contact request'**
  String get incomingPairingTitle;

  /// No description provided for @pairingCompletedTitle.
  ///
  /// In en, this message translates to:
  /// **'Contact added'**
  String get pairingCompletedTitle;

  /// No description provided for @pairingCompletedDescription.
  ///
  /// In en, this message translates to:
  /// **'A secure connection was confirmed on both sides.'**
  String get pairingCompletedDescription;

  /// No description provided for @newContact.
  ///
  /// In en, this message translates to:
  /// **'New contact'**
  String get newContact;

  /// No description provided for @pairingSavingDecision.
  ///
  /// In en, this message translates to:
  /// **'Saving decision…'**
  String get pairingSavingDecision;

  /// No description provided for @pairingAcceptedDescription.
  ///
  /// In en, this message translates to:
  /// **'The invitation was accepted. Contact finalization is running in the background.'**
  String get pairingAcceptedDescription;

  /// No description provided for @pairingWaitingDecision.
  ///
  /// In en, this message translates to:
  /// **'The invitation is waiting for your decision. It will not be automatically rejected by the interface timer.'**
  String get pairingWaitingDecision;

  /// No description provided for @securityDetails.
  ///
  /// In en, this message translates to:
  /// **'Security details'**
  String get securityDetails;

  /// No description provided for @contactFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Contact fingerprint'**
  String get contactFingerprint;

  /// No description provided for @accepting.
  ///
  /// In en, this message translates to:
  /// **'Accepting…'**
  String get accepting;

  /// No description provided for @reject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get reject;

  /// No description provided for @accept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get accept;

  /// No description provided for @checkingInvitations.
  ///
  /// In en, this message translates to:
  /// **'Checking for new invitations…'**
  String get checkingInvitations;

  /// No description provided for @waitingForCode.
  ///
  /// In en, this message translates to:
  /// **'Waiting for code use…'**
  String get waitingForCode;

  /// No description provided for @contactsAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get contactsAddTitle;

  /// No description provided for @contactsAddDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter a pairing code or scan a QR code'**
  String get contactsAddDescription;

  /// No description provided for @myPairingCode.
  ///
  /// In en, this message translates to:
  /// **'My pairing code'**
  String get myPairingCode;

  /// No description provided for @pairingCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the 8-digit contact code'**
  String get pairingCodeHint;

  /// No description provided for @processingPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Processing code…'**
  String get processingPairingCode;

  /// No description provided for @pairingCodeInputHint.
  ///
  /// In en, this message translates to:
  /// **'Enter an 8-digit pairing code'**
  String get pairingCodeInputHint;

  /// No description provided for @sendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get sendCode;

  /// No description provided for @yourFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Your fingerprint'**
  String get yourFingerprint;

  /// Accessibility label for the local fingerprint
  ///
  /// In en, this message translates to:
  /// **'Your fingerprint: {fingerprint}'**
  String yourFingerprintSemantics(String fingerprint);

  /// No description provided for @loadingContacts.
  ///
  /// In en, this message translates to:
  /// **'Loading contacts…'**
  String get loadingContacts;

  /// No description provided for @contactsTitle.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get contactsTitle;

  /// No description provided for @contactDetails.
  ///
  /// In en, this message translates to:
  /// **'Contact details'**
  String get contactDetails;

  /// No description provided for @contactStatusActive.
  ///
  /// In en, this message translates to:
  /// **'active in app'**
  String get contactStatusActive;

  /// No description provided for @contactStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'idle'**
  String get contactStatusIdle;

  /// No description provided for @contactStatusOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get contactStatusOffline;

  /// No description provided for @connectionCenterTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection center'**
  String get connectionCenterTitle;

  /// No description provided for @connectionInfrastructure.
  ///
  /// In en, this message translates to:
  /// **'Application infrastructure'**
  String get connectionInfrastructure;

  /// No description provided for @connectionCommunicationReadiness.
  ///
  /// In en, this message translates to:
  /// **'Communication readiness'**
  String get connectionCommunicationReadiness;

  /// No description provided for @connectionActivity.
  ///
  /// In en, this message translates to:
  /// **'Application activity'**
  String get connectionActivity;

  /// No description provided for @connectionDirectSessions.
  ///
  /// In en, this message translates to:
  /// **'Direct contact sessions'**
  String get connectionDirectSessions;

  /// No description provided for @connectionDirectSessionsDetail.
  ///
  /// In en, this message translates to:
  /// **'Sessions with specific contacts start after onboarding and do not block application startup.'**
  String get connectionDirectSessionsDetail;

  /// No description provided for @connectionContactPresence.
  ///
  /// In en, this message translates to:
  /// **'Contact presence'**
  String get connectionContactPresence;

  /// No description provided for @connectionContactPresenceDetail.
  ///
  /// In en, this message translates to:
  /// **'Contacts reporting active presence in the runtime.'**
  String get connectionContactPresenceDetail;

  /// No description provided for @connectionLocalConversationSummaries.
  ///
  /// In en, this message translates to:
  /// **'Local conversation summaries'**
  String get connectionLocalConversationSummaries;

  /// No description provided for @connectionLocalConversationSummariesDetail.
  ///
  /// In en, this message translates to:
  /// **'The conversation list comes from an atomic snapshot; messages load when opened.'**
  String get connectionLocalConversationSummariesDetail;

  /// No description provided for @connectionMessageQueue.
  ///
  /// In en, this message translates to:
  /// **'Message queue'**
  String get connectionMessageQueue;

  /// No description provided for @connectionQueueClean.
  ///
  /// In en, this message translates to:
  /// **'clean'**
  String get connectionQueueClean;

  /// Message queue counts
  ///
  /// In en, this message translates to:
  /// **'{queued} queued · {failed} failed'**
  String connectionQueueCounts(int queued, int failed);

  /// No description provided for @connectionMessageQueueDetail.
  ///
  /// In en, this message translates to:
  /// **'Messages remain in the durable queue until delivery is acknowledged.'**
  String get connectionMessageQueueDetail;

  /// No description provided for @connectionLastError.
  ///
  /// In en, this message translates to:
  /// **'Last error'**
  String get connectionLastError;

  /// No description provided for @contactActivityTyping.
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get contactActivityTyping;

  /// No description provided for @contactActivityOnline.
  ///
  /// In en, this message translates to:
  /// **'active in the app'**
  String get contactActivityOnline;

  /// No description provided for @contactActivityAway.
  ///
  /// In en, this message translates to:
  /// **'idle'**
  String get contactActivityAway;

  /// No description provided for @contactActivityUnknown.
  ///
  /// In en, this message translates to:
  /// **'status unknown'**
  String get contactActivityUnknown;

  /// No description provided for @contactActivityLastSeen.
  ///
  /// In en, this message translates to:
  /// **'last seen {label}'**
  String contactActivityLastSeen(Object label);

  /// No description provided for @contactActivityJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get contactActivityJustNow;

  /// No description provided for @contactActivityMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 min ago} other{{count} min ago}}'**
  String contactActivityMinutesAgo(num count);

  /// No description provided for @contactActivityHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hr ago} other{{count} hr ago}}'**
  String contactActivityHoursAgo(num count);

  /// No description provided for @contactActivityDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String contactActivityDaysAgo(num count);

  /// No description provided for @contactStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'status unknown'**
  String get contactStatusUnknown;

  /// No description provided for @contactStatusChecking.
  ///
  /// In en, this message translates to:
  /// **'checking'**
  String get contactStatusChecking;

  /// No description provided for @routeP2P.
  ///
  /// In en, this message translates to:
  /// **'P2P'**
  String get routeP2P;

  /// No description provided for @routeP2PFallback.
  ///
  /// In en, this message translates to:
  /// **'P2P + relay fallback'**
  String get routeP2PFallback;

  /// No description provided for @routeRelay.
  ///
  /// In en, this message translates to:
  /// **'relay'**
  String get routeRelay;

  /// No description provided for @messageReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get messageReply;

  /// No description provided for @messageCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy message'**
  String get messageCopy;

  /// No description provided for @messageRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get messageRetry;

  /// No description provided for @messageDeleteLocal.
  ///
  /// In en, this message translates to:
  /// **'Delete on this device only'**
  String get messageDeleteLocal;

  /// No description provided for @messageRetrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying…'**
  String get messageRetrying;

  /// No description provided for @messageDeleting.
  ///
  /// In en, this message translates to:
  /// **'Deleting…'**
  String get messageDeleting;

  /// No description provided for @messageStateQueued.
  ///
  /// In en, this message translates to:
  /// **'queued'**
  String get messageStateQueued;

  /// No description provided for @messageStateSending.
  ///
  /// In en, this message translates to:
  /// **'sending…'**
  String get messageStateSending;

  /// No description provided for @messageStateSent.
  ///
  /// In en, this message translates to:
  /// **'sent'**
  String get messageStateSent;

  /// No description provided for @messageStateDelivered.
  ///
  /// In en, this message translates to:
  /// **'delivered'**
  String get messageStateDelivered;

  /// No description provided for @messageStateRead.
  ///
  /// In en, this message translates to:
  /// **'read'**
  String get messageStateRead;

  /// No description provided for @messageStateFailed.
  ///
  /// In en, this message translates to:
  /// **'send failed'**
  String get messageStateFailed;

  /// No description provided for @chatStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting conversation…'**
  String get chatStarting;

  /// No description provided for @chatLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading conversation…'**
  String get chatLoading;

  /// No description provided for @chatBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get chatBack;

  /// No description provided for @chatSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search this conversation…'**
  String get chatSearchHint;

  /// No description provided for @chatContactViewing.
  ///
  /// In en, this message translates to:
  /// **'Contact is viewing this conversation'**
  String get chatContactViewing;

  /// No description provided for @chatCloseSearch.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get chatCloseSearch;

  /// No description provided for @chatSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatSearch;

  /// No description provided for @chatOptions.
  ///
  /// In en, this message translates to:
  /// **'Conversation options'**
  String get chatOptions;

  /// No description provided for @chatCopyFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Copy fingerprint'**
  String get chatCopyFingerprint;

  /// No description provided for @chatLoadingOlder.
  ///
  /// In en, this message translates to:
  /// **'Loading older messages…'**
  String get chatLoadingOlder;

  /// Number of unseen messages
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No new messages} =1{1 new message} other{{count} new messages}}'**
  String chatUnseenMessages(int count);

  /// No description provided for @chatScrollToBottom.
  ///
  /// In en, this message translates to:
  /// **'Scroll to bottom'**
  String get chatScrollToBottom;

  /// No description provided for @chatPrivateCommunication.
  ///
  /// In en, this message translates to:
  /// **'Private communication through Tor'**
  String get chatPrivateCommunication;

  /// Conversation home counts
  ///
  /// In en, this message translates to:
  /// **'{contacts} contacts · {conversations} conversations'**
  String chatCounts(int contacts, int conversations);

  /// No description provided for @chatRecentConversations.
  ///
  /// In en, this message translates to:
  /// **'Recent conversations'**
  String get chatRecentConversations;

  /// No description provided for @chatVerifyContact.
  ///
  /// In en, this message translates to:
  /// **'Verify the contact\'s identity in the details to start a conversation.'**
  String get chatVerifyContact;

  /// Empty conversation message
  ///
  /// In en, this message translates to:
  /// **'This is the beginning of your conversation with {name}.'**
  String chatConversationStarted(String name);

  /// No description provided for @chatSecureConnectionStarting.
  ///
  /// In en, this message translates to:
  /// **'Establishing a secure connection'**
  String get chatSecureConnectionStarting;

  /// No description provided for @chatWaitingForSecureConnection.
  ///
  /// In en, this message translates to:
  /// **'The conversation is waiting for a secure connection.'**
  String get chatWaitingForSecureConnection;

  /// No description provided for @chatRemoveAttachment.
  ///
  /// In en, this message translates to:
  /// **'Remove attachment'**
  String get chatRemoveAttachment;

  /// No description provided for @chatCancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get chatCancelReply;

  /// No description provided for @chatPreparingImages.
  ///
  /// In en, this message translates to:
  /// **'Preparing images…'**
  String get chatPreparingImages;

  /// No description provided for @chatAddImages.
  ///
  /// In en, this message translates to:
  /// **'Add images to message'**
  String get chatAddImages;

  /// No description provided for @chatComposeHint.
  ///
  /// In en, this message translates to:
  /// **'Write a message…'**
  String get chatComposeHint;

  /// No description provided for @chatNotReady.
  ///
  /// In en, this message translates to:
  /// **'Conversation is not ready yet'**
  String get chatNotReady;

  /// No description provided for @statusTransportConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to relay through Tor'**
  String get statusTransportConnected;

  /// No description provided for @statusTransportStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting Tor'**
  String get statusTransportStarting;

  /// No description provided for @statusTransportBootstrapping.
  ///
  /// In en, this message translates to:
  /// **'Bootstrapping Tor circuit'**
  String get statusTransportBootstrapping;

  /// No description provided for @statusTransportConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to onion relay'**
  String get statusTransportConnecting;

  /// No description provided for @statusTransportDegraded.
  ///
  /// In en, this message translates to:
  /// **'Relay is operating in limited mode'**
  String get statusTransportDegraded;

  /// No description provided for @statusTransportReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to relay'**
  String get statusTransportReconnecting;

  /// No description provided for @statusTransportOffline.
  ///
  /// In en, this message translates to:
  /// **'Tor offline'**
  String get statusTransportOffline;

  /// No description provided for @statusTransportError.
  ///
  /// In en, this message translates to:
  /// **'Checking Tor connection'**
  String get statusTransportError;

  /// No description provided for @statusComponentEngine.
  ///
  /// In en, this message translates to:
  /// **'Application engine'**
  String get statusComponentEngine;

  /// No description provided for @statusComponentLocalData.
  ///
  /// In en, this message translates to:
  /// **'Local data'**
  String get statusComponentLocalData;

  /// No description provided for @statusComponentTor.
  ///
  /// In en, this message translates to:
  /// **'Tor network'**
  String get statusComponentTor;

  /// No description provided for @statusComponentRelay.
  ///
  /// In en, this message translates to:
  /// **'TorChat relay'**
  String get statusComponentRelay;

  /// No description provided for @statusComponentPeerListener.
  ///
  /// In en, this message translates to:
  /// **'Local P2P listener'**
  String get statusComponentPeerListener;

  /// No description provided for @statusComponentOnionService.
  ///
  /// In en, this message translates to:
  /// **'This device\'s onion service'**
  String get statusComponentOnionService;

  /// No description provided for @statusComponentEngineDescription.
  ///
  /// In en, this message translates to:
  /// **'Shared messenger engine'**
  String get statusComponentEngineDescription;

  /// No description provided for @statusComponentLocalDataDescription.
  ///
  /// In en, this message translates to:
  /// **'Identity and encrypted local database'**
  String get statusComponentLocalDataDescription;

  /// No description provided for @statusComponentTorDescription.
  ///
  /// In en, this message translates to:
  /// **'Tor process and local SOCKS endpoint'**
  String get statusComponentTorDescription;

  /// No description provided for @statusComponentRelayDescription.
  ///
  /// In en, this message translates to:
  /// **'Control connection to the onion relay'**
  String get statusComponentRelayDescription;

  /// No description provided for @statusComponentPeerListenerDescription.
  ///
  /// In en, this message translates to:
  /// **'Local server accepting peer connections'**
  String get statusComponentPeerListenerDescription;

  /// No description provided for @statusComponentOnionServiceDescription.
  ///
  /// In en, this message translates to:
  /// **'Onion address published for this device'**
  String get statusComponentOnionServiceDescription;

  /// No description provided for @desktopChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get desktopChats;

  /// Desktop conversation count
  ///
  /// In en, this message translates to:
  /// **'{count} conversations'**
  String desktopConversationCount(int count);

  /// No description provided for @desktopSearch.
  ///
  /// In en, this message translates to:
  /// **'Search…'**
  String get desktopSearch;

  /// No description provided for @desktopNoConversations.
  ///
  /// In en, this message translates to:
  /// **'You have no conversations yet.'**
  String get desktopNoConversations;

  /// No description provided for @desktopNoConversationMatches.
  ///
  /// In en, this message translates to:
  /// **'No conversations match your search.'**
  String get desktopNoConversationMatches;

  /// No description provided for @desktopContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get desktopContacts;

  /// No description provided for @desktopFilteredContactsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No contacts match the selected filter.'**
  String get desktopFilteredContactsEmpty;

  /// Desktop contact count
  ///
  /// In en, this message translates to:
  /// **'{count} saved'**
  String desktopContactCount(int count);

  /// No description provided for @desktopSearchContacts.
  ///
  /// In en, this message translates to:
  /// **'Search contacts…'**
  String get desktopSearchContacts;

  /// No description provided for @desktopAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get desktopAll;

  /// No description provided for @desktopOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get desktopOnline;

  /// No description provided for @commonYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get commonYes;

  /// No description provided for @commonNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get commonNo;

  /// No description provided for @desktopContactDetails.
  ///
  /// In en, this message translates to:
  /// **'Contact details'**
  String get desktopContactDetails;

  /// No description provided for @desktopCloseDetails.
  ///
  /// In en, this message translates to:
  /// **'Close details'**
  String get desktopCloseDetails;

  /// No description provided for @desktopContactSection.
  ///
  /// In en, this message translates to:
  /// **'CONTACT'**
  String get desktopContactSection;

  /// No description provided for @desktopIdentityVerified.
  ///
  /// In en, this message translates to:
  /// **'Identity verified'**
  String get desktopIdentityVerified;

  /// No description provided for @desktopIdentityUnverified.
  ///
  /// In en, this message translates to:
  /// **'Identity not verified'**
  String get desktopIdentityUnverified;

  /// No description provided for @desktopVerifyIdentity.
  ///
  /// In en, this message translates to:
  /// **'Verify identity'**
  String get desktopVerifyIdentity;

  /// No description provided for @desktopPresenceSection.
  ///
  /// In en, this message translates to:
  /// **'PRESENCE'**
  String get desktopPresenceSection;

  /// No description provided for @desktopStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get desktopStatus;

  /// No description provided for @desktopLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last seen'**
  String get desktopLastSeen;

  /// No description provided for @desktopObserved.
  ///
  /// In en, this message translates to:
  /// **'Observed'**
  String get desktopObserved;

  /// No description provided for @desktopObservationExpiry.
  ///
  /// In en, this message translates to:
  /// **'Observation expiry'**
  String get desktopObservationExpiry;

  /// No description provided for @desktopConversationFocus.
  ///
  /// In en, this message translates to:
  /// **'Conversation focus'**
  String get desktopConversationFocus;

  /// No description provided for @desktopConnectionSection.
  ///
  /// In en, this message translates to:
  /// **'CONNECTION'**
  String get desktopConnectionSection;

  /// No description provided for @desktopP2pConnection.
  ///
  /// In en, this message translates to:
  /// **'P2P connection'**
  String get desktopP2pConnection;

  /// No description provided for @desktopProbeLatency.
  ///
  /// In en, this message translates to:
  /// **'Probe latency'**
  String get desktopProbeLatency;

  /// No description provided for @desktopNextProbe.
  ///
  /// In en, this message translates to:
  /// **'Next probe'**
  String get desktopNextProbe;

  /// No description provided for @desktopLastP2pConnection.
  ///
  /// In en, this message translates to:
  /// **'Last P2P connection'**
  String get desktopLastP2pConnection;

  /// No description provided for @desktopRoute.
  ///
  /// In en, this message translates to:
  /// **'Route'**
  String get desktopRoute;

  /// No description provided for @desktopEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Endpoint'**
  String get desktopEndpoint;

  /// No description provided for @desktopPolicy.
  ///
  /// In en, this message translates to:
  /// **'Policy'**
  String get desktopPolicy;

  /// No description provided for @desktopInformationSection.
  ///
  /// In en, this message translates to:
  /// **'INFORMATION'**
  String get desktopInformationSection;

  /// No description provided for @desktopInstallationId.
  ///
  /// In en, this message translates to:
  /// **'Installation ID'**
  String get desktopInstallationId;

  /// No description provided for @desktopLastP2p.
  ///
  /// In en, this message translates to:
  /// **'Last P2P'**
  String get desktopLastP2p;

  /// No description provided for @desktopBackToConversations.
  ///
  /// In en, this message translates to:
  /// **'Back to conversation list'**
  String get desktopBackToConversations;

  /// No description provided for @statusProbeEngine.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get statusProbeEngine;

  /// No description provided for @statusProbeRelay.
  ///
  /// In en, this message translates to:
  /// **'Tor relay'**
  String get statusProbeRelay;

  /// No description provided for @statusProbePeer.
  ///
  /// In en, this message translates to:
  /// **'Tor P2P'**
  String get statusProbePeer;

  /// No description provided for @startupEngine.
  ///
  /// In en, this message translates to:
  /// **'Shared engine'**
  String get startupEngine;

  /// No description provided for @startupLocalData.
  ///
  /// In en, this message translates to:
  /// **'Local data'**
  String get startupLocalData;

  /// No description provided for @startupTor.
  ///
  /// In en, this message translates to:
  /// **'Tor network'**
  String get startupTor;

  /// No description provided for @startupPeerListener.
  ///
  /// In en, this message translates to:
  /// **'Local P2P server'**
  String get startupPeerListener;

  /// No description provided for @startupOnionService.
  ///
  /// In en, this message translates to:
  /// **'P2P onion service'**
  String get startupOnionService;

  /// No description provided for @startupRelay.
  ///
  /// In en, this message translates to:
  /// **'Tor relay'**
  String get startupRelay;

  /// No description provided for @startupCommunication.
  ///
  /// In en, this message translates to:
  /// **'Communication readiness'**
  String get startupCommunication;

  /// No description provided for @startupEngineDescription.
  ///
  /// In en, this message translates to:
  /// **'Starting shared Rust engine'**
  String get startupEngineDescription;

  /// No description provided for @startupLocalDataDescription.
  ///
  /// In en, this message translates to:
  /// **'Opening encrypted database and identity'**
  String get startupLocalDataDescription;

  /// No description provided for @startupTorDescription.
  ///
  /// In en, this message translates to:
  /// **'Starting Tor and preparing SOCKS'**
  String get startupTorDescription;

  /// No description provided for @startupPeerListenerDescription.
  ///
  /// In en, this message translates to:
  /// **'Listening on the local peer server'**
  String get startupPeerListenerDescription;

  /// No description provided for @startupOnionServiceDescription.
  ///
  /// In en, this message translates to:
  /// **'Publishing this device\'s onion address'**
  String get startupOnionServiceDescription;

  /// No description provided for @startupRelayDescription.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the control server'**
  String get startupRelayDescription;

  /// No description provided for @startupCommunicationDescription.
  ///
  /// In en, this message translates to:
  /// **'Message queues and receiving'**
  String get startupCommunicationDescription;

  /// Accessibility label for a contact
  ///
  /// In en, this message translates to:
  /// **'Contact {name}'**
  String contactSemantics(String name);

  /// No description provided for @contactSemanticsHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to start a conversation. Hold to open the menu.'**
  String get contactSemanticsHint;

  /// No description provided for @contactStartConversation.
  ///
  /// In en, this message translates to:
  /// **'Start conversation'**
  String get contactStartConversation;

  /// No description provided for @contactEnableNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable notifications'**
  String get contactEnableNotifications;

  /// No description provided for @contactMute.
  ///
  /// In en, this message translates to:
  /// **'Mute contact'**
  String get contactMute;

  /// No description provided for @contactCopyFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Copy fingerprint'**
  String get contactCopyFingerprint;

  /// No description provided for @contactEndRelationship.
  ///
  /// In en, this message translates to:
  /// **'End relationship'**
  String get contactEndRelationship;

  /// No description provided for @conversationsLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading conversations…'**
  String get conversationsLoading;

  /// No description provided for @conversationRename.
  ///
  /// In en, this message translates to:
  /// **'Rename locally'**
  String get conversationRename;

  /// No description provided for @conversationUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get conversationUnpin;

  /// No description provided for @conversationPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get conversationPin;

  /// No description provided for @conversationEnableNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable notifications'**
  String get conversationEnableNotifications;

  /// No description provided for @conversationMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get conversationMute;

  /// No description provided for @conversationClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear local history'**
  String get conversationClearHistory;

  /// No description provided for @conversationArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive locally'**
  String get conversationArchive;

  /// No description provided for @conversationLocalName.
  ///
  /// In en, this message translates to:
  /// **'Local conversation name'**
  String get conversationLocalName;

  /// No description provided for @conversationName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get conversationName;

  /// No description provided for @conversationNameLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'This name stays on this device.'**
  String get conversationNameLocalOnly;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @conversationRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get conversationRestore;

  /// No description provided for @conversationClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear local history?'**
  String get conversationClearHistoryTitle;

  /// No description provided for @conversationClearHistoryDescription.
  ///
  /// In en, this message translates to:
  /// **'Messages will be deleted only from this device. The contact will not be notified.'**
  String get conversationClearHistoryDescription;

  /// No description provided for @conversationClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get conversationClear;

  /// No description provided for @conversationHistoryCleared.
  ///
  /// In en, this message translates to:
  /// **'Local history cleared.'**
  String get conversationHistoryCleared;

  /// No description provided for @problemPairingWelcomeStale.
  ///
  /// In en, this message translates to:
  /// **'This invitation can no longer be completed. Ask the contact to generate a new pairing code.'**
  String get problemPairingWelcomeStale;

  /// No description provided for @problemPairingCodeInvalid.
  ///
  /// In en, this message translates to:
  /// **'The pairing code is invalid or expired. Ask the contact for a new code.'**
  String get problemPairingCodeInvalid;

  /// No description provided for @problemPairingRequiresRelay.
  ///
  /// In en, this message translates to:
  /// **'Pairing requires an available relay; local data remains available offline.'**
  String get problemPairingRequiresRelay;

  /// No description provided for @problemNicknameRequired.
  ///
  /// In en, this message translates to:
  /// **'Set a username on this device first.'**
  String get problemNicknameRequired;

  /// No description provided for @problemInviteCodeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The relay did not return an invitation code. Try again.'**
  String get problemInviteCodeUnavailable;

  /// No description provided for @problemPairingGatewayUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The pairing service is temporarily unavailable. Try again shortly.'**
  String get problemPairingGatewayUnavailable;

  /// No description provided for @problemSecureConnectionPending.
  ///
  /// In en, this message translates to:
  /// **'The secure connection is not ready yet.'**
  String get problemSecureConnectionPending;

  /// No description provided for @problemConnectionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The connection is temporarily unavailable.'**
  String get problemConnectionUnavailable;

  /// No description provided for @problemOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation could not be completed.'**
  String get problemOperationFailed;

  /// No description provided for @paletteArcade.
  ///
  /// In en, this message translates to:
  /// **'Arcade'**
  String get paletteArcade;

  /// No description provided for @paletteMocha.
  ///
  /// In en, this message translates to:
  /// **'Mocha'**
  String get paletteMocha;

  /// No description provided for @paletteGruvbox.
  ///
  /// In en, this message translates to:
  /// **'Gruvbox'**
  String get paletteGruvbox;

  /// No description provided for @paletteNord.
  ///
  /// In en, this message translates to:
  /// **'Nord'**
  String get paletteNord;

  /// No description provided for @shellAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get shellAccount;

  /// No description provided for @shellSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get shellSettings;

  /// No description provided for @contactsLocalAlias.
  ///
  /// In en, this message translates to:
  /// **'Local alias'**
  String get contactsLocalAlias;

  /// No description provided for @contactsSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get contactsSaving;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @relationshipEndTitle.
  ///
  /// In en, this message translates to:
  /// **'End relationship?'**
  String get relationshipEndTitle;

  /// Relationship removal warning
  ///
  /// In en, this message translates to:
  /// **'Contact {name} will no longer be able to send messages. Adding them again will require a new code.'**
  String relationshipEndDescription(String name);

  /// No description provided for @relationshipKeepHistory.
  ///
  /// In en, this message translates to:
  /// **'Keep history on this device'**
  String get relationshipKeepHistory;

  /// No description provided for @relationshipKeepHistoryDescription.
  ///
  /// In en, this message translates to:
  /// **'History remains local and will not restore the relationship.'**
  String get relationshipKeepHistoryDescription;

  /// No description provided for @imageDownload.
  ///
  /// In en, this message translates to:
  /// **'Download image'**
  String get imageDownload;

  /// No description provided for @imageSaveToGallery.
  ///
  /// In en, this message translates to:
  /// **'Save to gallery'**
  String get imageSaveToGallery;

  /// No description provided for @imageRemoveFromCache.
  ///
  /// In en, this message translates to:
  /// **'Remove from encrypted cache'**
  String get imageRemoveFromCache;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get commonRetry;

  /// No description provided for @commonDeleteLocal.
  ///
  /// In en, this message translates to:
  /// **'Delete on this device only'**
  String get commonDeleteLocal;

  /// No description provided for @connectionDiagnosticsCopied.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics copied.'**
  String get connectionDiagnosticsCopied;

  /// No description provided for @connectionCopyDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Copy diagnostics'**
  String get connectionCopyDiagnostics;

  /// No description provided for @connectionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry connection'**
  String get connectionRetry;

  /// No description provided for @connectionRetrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying…'**
  String get connectionRetrying;

  /// No description provided for @commonContact.
  ///
  /// In en, this message translates to:
  /// **'Contact'**
  String get commonContact;

  /// No description provided for @commonImage.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get commonImage;

  /// No description provided for @chatWaitingForMessage.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a message'**
  String get chatWaitingForMessage;

  /// No description provided for @contactsRotate.
  ///
  /// In en, this message translates to:
  /// **'Rotate'**
  String get contactsRotate;

  /// No description provided for @contactsRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get contactsRevoke;

  /// No description provided for @contactsNoDeadLetters.
  ///
  /// In en, this message translates to:
  /// **'No dead letters'**
  String get contactsNoDeadLetters;

  /// No description provided for @contactsDeadLetterRetry.
  ///
  /// In en, this message translates to:
  /// **'Dead-letter retry'**
  String get contactsDeadLetterRetry;

  /// No description provided for @contactsNoError.
  ///
  /// In en, this message translates to:
  /// **'No error'**
  String get contactsNoError;

  /// No description provided for @contactsSavingSettings.
  ///
  /// In en, this message translates to:
  /// **'Saving settings…'**
  String get contactsSavingSettings;

  /// No description provided for @contactsEstablishedByPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Relationship established by accepted code'**
  String get contactsEstablishedByPairingCode;

  /// No description provided for @contactsP2pThroughTor.
  ///
  /// In en, this message translates to:
  /// **'P2P through Tor'**
  String get contactsP2pThroughTor;

  /// No description provided for @contactsDirectConnection.
  ///
  /// In en, this message translates to:
  /// **'Direct connection'**
  String get contactsDirectConnection;

  /// No description provided for @contactsCurrentRoute.
  ///
  /// In en, this message translates to:
  /// **'Current route'**
  String get contactsCurrentRoute;

  /// No description provided for @contactsPresence.
  ///
  /// In en, this message translates to:
  /// **'Presence'**
  String get contactsPresence;

  /// No description provided for @contactsViewingConversation.
  ///
  /// In en, this message translates to:
  /// **'Viewing conversation'**
  String get contactsViewingConversation;

  /// No description provided for @contactsLastProbe.
  ///
  /// In en, this message translates to:
  /// **'Last probe'**
  String get contactsLastProbe;

  /// No description provided for @contactsNoData.
  ///
  /// In en, this message translates to:
  /// **'no data'**
  String get contactsNoData;

  /// No description provided for @contactsProbeLatency.
  ///
  /// In en, this message translates to:
  /// **'Probe latency'**
  String get contactsProbeLatency;

  /// No description provided for @contactsP2pCapability.
  ///
  /// In en, this message translates to:
  /// **'P2P endpoint capability'**
  String get contactsP2pCapability;

  /// No description provided for @contactsCapabilityUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Capability status unavailable'**
  String get contactsCapabilityUnavailable;

  /// No description provided for @contactRouteRelay.
  ///
  /// In en, this message translates to:
  /// **'relay'**
  String get contactRouteRelay;

  /// No description provided for @contactRouteP2pOnion.
  ///
  /// In en, this message translates to:
  /// **'P2P onion'**
  String get contactRouteP2pOnion;

  /// No description provided for @contactRouteRelayFallback.
  ///
  /// In en, this message translates to:
  /// **'live relay fallback (P2P inactive)'**
  String get contactRouteRelayFallback;

  /// No description provided for @contactRouteP2pOffline.
  ///
  /// In en, this message translates to:
  /// **'P2P waiting / offline'**
  String get contactRouteP2pOffline;

  /// No description provided for @contactEndpointVerified.
  ///
  /// In en, this message translates to:
  /// **'endpoint verified'**
  String get contactEndpointVerified;

  /// No description provided for @contactEndpointPending.
  ///
  /// In en, this message translates to:
  /// **'waiting for endpoint exchange'**
  String get contactEndpointPending;

  /// No description provided for @contactEndpointInvalid.
  ///
  /// In en, this message translates to:
  /// **'invalid endpoint'**
  String get contactEndpointInvalid;

  /// No description provided for @contactEndpointMissing.
  ///
  /// In en, this message translates to:
  /// **'endpoint unavailable'**
  String get contactEndpointMissing;

  /// No description provided for @contactAvailabilityActive.
  ///
  /// In en, this message translates to:
  /// **'active in app'**
  String get contactAvailabilityActive;

  /// No description provided for @contactAvailabilityIdle.
  ///
  /// In en, this message translates to:
  /// **'idle'**
  String get contactAvailabilityIdle;

  /// No description provided for @contactAvailabilityChecking.
  ///
  /// In en, this message translates to:
  /// **'checking'**
  String get contactAvailabilityChecking;

  /// No description provided for @contactAvailabilityOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get contactAvailabilityOffline;

  /// No description provided for @contactAvailabilityUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown status'**
  String get contactAvailabilityUnknown;

  /// No description provided for @contactPeerConnected.
  ///
  /// In en, this message translates to:
  /// **'connected'**
  String get contactPeerConnected;

  /// No description provided for @contactPeerConnecting.
  ///
  /// In en, this message translates to:
  /// **'connecting'**
  String get contactPeerConnecting;

  /// No description provided for @contactPeerAuthenticating.
  ///
  /// In en, this message translates to:
  /// **'authenticating'**
  String get contactPeerAuthenticating;

  /// No description provided for @contactPeerBackoff.
  ///
  /// In en, this message translates to:
  /// **'waiting to retry'**
  String get contactPeerBackoff;

  /// No description provided for @contactPeerOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get contactPeerOffline;

  /// No description provided for @contactPeerUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get contactPeerUnknown;

  /// No description provided for @contactPolicyP2pOnly.
  ///
  /// In en, this message translates to:
  /// **'P2P only'**
  String get contactPolicyP2pOnly;

  /// No description provided for @contactPolicyFallback.
  ///
  /// In en, this message translates to:
  /// **'P2P + live relay fallback'**
  String get contactPolicyFallback;

  /// No description provided for @contactsNewContact.
  ///
  /// In en, this message translates to:
  /// **'New contact'**
  String get contactsNewContact;

  /// No description provided for @contactsWaitingForSecureConversation.
  ///
  /// In en, this message translates to:
  /// **'Waiting to establish a secure conversation'**
  String get contactsWaitingForSecureConversation;

  /// No description provided for @contactsTransportPolicy.
  ///
  /// In en, this message translates to:
  /// **'Transport policy'**
  String get contactsTransportPolicy;

  /// No description provided for @onboardingNicknameLabel.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get onboardingNicknameLabel;

  /// No description provided for @onboardingSaveNickname.
  ///
  /// In en, this message translates to:
  /// **'Save nickname'**
  String get onboardingSaveNickname;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Private messages through Tor'**
  String get appTagline;

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// Minutes elapsed since an event
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String timeMinutesAgo(int count);

  /// Hours elapsed since an event
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String timeHoursAgo(int count);

  /// Days elapsed since an event
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String timeDaysAgo(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pl'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pl':
      return AppLocalizationsPl();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
