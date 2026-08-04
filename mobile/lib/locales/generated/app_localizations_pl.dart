// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Polish (`pl`).
class AppLocalizationsPl extends AppLocalizations {
  AppLocalizationsPl([String locale = 'pl']) : super(locale);

  @override
  String get appTitle => 'TorChat';

  @override
  String get languageSetupTitle => 'Wybierz język';

  @override
  String get languageSetupDescription => 'Później zmienisz go w ustawieniach.';

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
  String get languageSettingsTitle => 'Język';

  @override
  String get languageSettingsDescription =>
      'Wybierz język używany przez TorChat.';

  @override
  String get notificationNewMessageTitle => 'Nowa wiadomość';

  @override
  String get notificationPairingRequestTitle => 'Nowa prośba kontaktu';

  @override
  String get notificationPrivateMessageBody => 'Nowa zaszyfrowana wiadomość';

  @override
  String get notificationPairingRequestBody => 'Masz nową prośbę o rozmowę.';

  @override
  String get settingsTitle => 'Ustawienia';

  @override
  String get settingsApplicationSection => 'APLIKACJA';

  @override
  String get settingsFamilyTitle => 'Rodzina';

  @override
  String get settingsFamilyDescription =>
      'Classic: klasyczny, Retro: styl retro';

  @override
  String get settingsClassic => 'Classic';

  @override
  String get settingsRetro => 'Retro';

  @override
  String get settingsTerminalPalette => 'Paleta terminalowa';

  @override
  String get settingsBrightness => 'Tryb jasności';

  @override
  String get settingsSystem => 'System';

  @override
  String get settingsLight => 'Jasny';

  @override
  String get settingsDark => 'Ciemny';

  @override
  String get settingsReduceMotion => 'Ogranicz animacje';

  @override
  String get settingsReduceMotionDescription =>
      'Wyłącza animacje i płynne przejścia w całej aplikacji';

  @override
  String get settingsWindowsAutostart => 'Uruchamiaj z systemem Windows';

  @override
  String get settingsWindowsAutostartDescription =>
      'Uruchamia TorChat automatycznie po zalogowaniu';

  @override
  String get settingsSaving => 'Zapisywanie…';

  @override
  String get settingsLastSeen => 'Ostatnio widziany';

  @override
  String get settingsLastSeenDescription =>
      'Udostępnia czas ostatniej aktywności kontaktom';

  @override
  String get settingsTorConnection => 'Połączenie Tor';

  @override
  String get settingsUserProfile => 'Profil użytkownika';

  @override
  String get settingsSavingProfile => 'Zapisywanie profilu…';

  @override
  String get settingsResetDemoData => 'Reset danych demo';

  @override
  String get settingsRequiresConfirmation => 'Wymaga potwierdzenia';

  @override
  String get settingsClearLocalState => 'Wyczyść lokalny stan';

  @override
  String get settingsClearLocalStateDescription =>
      'Usuwa wszystkie dane testowe i lokalne wpisy';

  @override
  String get settingsNotifications => 'Powiadomienia';

  @override
  String get settingsNotificationsDescription =>
      'Nadrzędny przełącznik wszystkich alertów';

  @override
  String get settingsNewMessages => 'Nowe wiadomości';

  @override
  String get settingsNewMessagesDescription =>
      'Powiadamiaj o wiadomościach poza otwartą rozmową';

  @override
  String get settingsContactInvitations => 'Zaproszenia do kontaktów';

  @override
  String get settingsContactInvitationsDescription =>
      'Powiadamiaj wyłącznie o nowych prośbach pairing';

  @override
  String get settingsNotificationSound => 'Dźwięk';

  @override
  String get settingsNotificationSoundDescription =>
      'Systemowy dźwięk powiadomienia TorChat';

  @override
  String get settingsNotificationVibration => 'Wibracja';

  @override
  String get settingsNotificationVibrationDescription =>
      'Wibracja dla zdarzeń przychodzących';

  @override
  String get settingsMessagePreview => 'Podgląd treści';

  @override
  String get settingsMessagePreviewDescription =>
      'Wyłączone domyślnie dla prywatności';

  @override
  String get settingsReadReceipts => 'Potwierdzenia odczytu';

  @override
  String get settingsReadReceiptsDescription =>
      'Informuj kontakt, że wiadomość została odczytana';

  @override
  String get settingsTypingIndicator => 'Informacja „pisze…”';

  @override
  String get settingsTypingIndicatorDescription =>
      'Udostępnia chwilową aktywność podczas pisania';

  @override
  String get settingsOnlineStatus => 'Status online';

  @override
  String get settingsOnlineStatusDescription =>
      'Udostępnia tylko bieżącą obecność bez historii';

  @override
  String get settingsNotificationsSection => 'POWIADOMIENIA';

  @override
  String get settingsChatPrivacySection => 'PRYWATNOŚĆ CZATU';

  @override
  String get settingsIdentitySection => 'TOŻSAMOŚĆ';

  @override
  String get settingsLocalDataSection => 'DANE LOKALNE';

  @override
  String get accountTitle => 'Konto';

  @override
  String get accountIdentitySection => 'TOŻSAMOŚĆ';

  @override
  String get accountLocalProfile => 'Lokalny profil urządzenia';

  @override
  String accountInstallationId(Object id) {
    return 'ID instalacji: $id';
  }

  @override
  String get accountActionsSection => 'AKCJE';

  @override
  String get accountInviteCode => 'Mój kod zaproszenia';

  @override
  String get accountInviteLoading => 'Pobieranie kodu…';

  @override
  String get accountInviteSubtitle => 'Kod jest widoczny tylko w osobnym oknie';

  @override
  String get accountSettings => 'Ustawienia';

  @override
  String get accountSettingsSubtitle => 'Otwórz ustawienia aplikacji';

  @override
  String get imageCacheSection => 'OBRAZY I CACHE';

  @override
  String get imageCacheClearTitle => 'Wyczyścić cache obrazów?';

  @override
  String get imageCacheClearDescription =>
      'Usuwa wyłącznie lokalne zaszyfrowane kopie obrazów. Wiadomości i historia rozmów pozostaną bez zmian.';

  @override
  String get cancel => 'Anuluj';

  @override
  String get clear => 'Wyczyść';

  @override
  String get imageAutoDownload => 'Automatycznie pobieraj obrazy';

  @override
  String get imageAutoDownloadDescription =>
      'Zapisuje przychodzące obrazy w lokalnym magazynie AES-GCM';

  @override
  String get encryptedCache => 'Zaszyfrowany cache';

  @override
  String get calculatingUsage => 'Obliczanie użycia…';

  @override
  String imageFilesCount(Object count, Object size) {
    return '$count plików · $size';
  }

  @override
  String get imageCacheClearing => 'Czyszczenie…';

  @override
  String get imageCacheClearButton => 'Wyczyść cache obrazów';

  @override
  String get imageCacheCleared => 'Cache obrazów został wyczyszczony.';

  @override
  String get nicknameSaving => 'Zapisywanie nicku…';

  @override
  String get nicknameReady => 'TorChat jest gotowy';

  @override
  String get nicknameDescription =>
      'Relay i onion tego urządzenia są aktywne. Ustaw lokalną nazwę użytkownika.';

  @override
  String get nicknameLabel => 'Nick';

  @override
  String get nicknameSave => 'Zapisz nick';

  @override
  String get retry => 'Spróbuj ponownie';

  @override
  String get warmupTitle => 'Rozgrzewanie TorChat';

  @override
  String get warmupSubtitle => 'Prywatne wiadomości przez Tor';

  @override
  String get communicationReady => 'Gotowość komunikacji';

  @override
  String get inviteScanTitle => 'Zeskanuj kod parowania';

  @override
  String get addContactTitle => 'Dodaj kontakt';

  @override
  String get processingCode => 'Przetwarzanie kodu…';

  @override
  String get desktopCodeInstructions =>
      'Desktop nie używa kamery. Wpisz 8-cyfrowy kod wyświetlony na drugim urządzeniu.';

  @override
  String get pairingCodeLabel => 'Kod parowania';

  @override
  String get pairingDialogTitle => 'Twój kod parowania';

  @override
  String get pairingRefreshing => 'Odświeżanie kodu…';

  @override
  String get pairingRefreshingAction => 'Odświeżanie…';

  @override
  String get pairingExpiredRefreshing => 'Kod wygasł · odświeżanie…';

  @override
  String pairingValidFor(String time) {
    return 'Ważny jeszcze $time';
  }

  @override
  String get pairingRefreshCode => 'Odśwież kod';

  @override
  String get close => 'Zamknij';

  @override
  String get incomingPairingTitle => 'Nowe zaproszenie do kontaktów';

  @override
  String get pairingCompletedTitle => 'Kontakt został dodany';

  @override
  String get pairingCompletedDescription =>
      'Bezpieczne połączenie zostało potwierdzone po obu stronach.';

  @override
  String get newContact => 'Nowy kontakt';

  @override
  String get pairingSavingDecision => 'Zapisywanie decyzji…';

  @override
  String get pairingAcceptedDescription =>
      'Zaproszenie zaakceptowane. Finalizacja kontaktu przebiega w tle.';

  @override
  String get pairingWaitingDecision =>
      'Zaproszenie oczekuje na Twoją decyzję. Nie zostanie automatycznie odrzucone przez licznik interfejsu.';

  @override
  String get securityDetails => 'Szczegóły bezpieczeństwa';

  @override
  String get contactFingerprint => 'Fingerprint klucza kontaktu';

  @override
  String get accepting => 'Akceptowanie…';

  @override
  String get reject => 'Odrzuć';

  @override
  String get accept => 'Akceptuj';

  @override
  String get checkingInvitations => 'Sprawdzanie nowych zaproszeń…';

  @override
  String get waitingForCode => 'Oczekiwanie na użycie kodu…';

  @override
  String get contactsAddTitle => 'Dodaj kontakt';

  @override
  String get contactsAddDescription => 'Wpisz kod parowania albo zeskanuj QR';

  @override
  String get myPairingCode => 'Mój kod parowania';

  @override
  String get pairingCodeHint => 'Wpisz ośmiocyfrowy kod kontaktu';

  @override
  String get processingPairingCode => 'Przetwarzanie kodu…';

  @override
  String get pairingCodeInputHint => 'Wpisz 8-cyfrowy kod parowania';

  @override
  String get sendCode => 'Wyślij kod';

  @override
  String get yourFingerprint => 'Twój fingerprint';

  @override
  String yourFingerprintSemantics(String fingerprint) {
    return 'Twój fingerprint: $fingerprint';
  }

  @override
  String get loadingContacts => 'Ładowanie kontaktów…';

  @override
  String get contactsTitle => 'Kontakty';

  @override
  String get contactDetails => 'Szczegóły kontaktu';

  @override
  String get contactStatusActive => 'aktywny w aplikacji';

  @override
  String get contactStatusIdle => 'bezczynny';

  @override
  String get contactStatusOffline => 'offline';

  @override
  String get connectionCenterTitle => 'Centrum połączeń';

  @override
  String get connectionInfrastructure => 'Infrastruktura aplikacji';

  @override
  String get connectionCommunicationReadiness => 'Gotowość komunikacji';

  @override
  String get connectionActivity => 'Aktywność w aplikacji';

  @override
  String get connectionDirectSessions => 'Bezpośrednie sesje kontaktów';

  @override
  String get connectionDirectSessionsDetail =>
      'Sesje z konkretnymi kontaktami powstają po onboardingu i nie blokują startu aplikacji.';

  @override
  String get connectionContactPresence => 'Obecność kontaktów';

  @override
  String get connectionContactPresenceDetail =>
      'Kontakty zgłaszające aktywną obecność w runtime.';

  @override
  String get connectionLocalConversationSummaries =>
      'Lokalne podsumowania rozmów';

  @override
  String get connectionLocalConversationSummariesDetail =>
      'Lista rozmów pochodzi z atomowego snapshotu; wiadomości są ładowane dopiero po otwarciu.';

  @override
  String get connectionMessageQueue => 'Kolejka wiadomości';

  @override
  String get connectionQueueClean => 'czysta';

  @override
  String connectionQueueCounts(int queued, int failed) {
    return '$queued oczekuje · $failed błędów';
  }

  @override
  String get connectionMessageQueueDetail =>
      'Wiadomości pozostają w trwałej kolejce do czasu potwierdzenia dostawy.';

  @override
  String get connectionLastError => 'Ostatni błąd';

  @override
  String get contactActivityTyping => 'pisze…';

  @override
  String get contactActivityOnline => 'aktywny w aplikacji';

  @override
  String get contactActivityAway => 'bezczynny';

  @override
  String get contactActivityUnknown => 'status nieznany';

  @override
  String contactActivityLastSeen(Object label) {
    return 'ostatnio widziany $label';
  }

  @override
  String get contactActivityJustNow => 'przed chwilą';

  @override
  String contactActivityMinutesAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min temu',
      many: '$count minut temu',
      few: '$count minuty temu',
      one: 'minutę temu',
    );
    return '$_temp0';
  }

  @override
  String contactActivityHoursAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count godz. temu',
      many: '$count godzin temu',
      few: '$count godziny temu',
      one: 'godzinę temu',
    );
    return '$_temp0';
  }

  @override
  String contactActivityDaysAgo(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dni temu',
      many: '$count dni temu',
      few: '$count dni temu',
      one: '1 dzień temu',
    );
    return '$_temp0';
  }

  @override
  String get contactStatusUnknown => 'status nieznany';

  @override
  String get contactStatusChecking => 'sprawdzanie';

  @override
  String get routeP2P => 'P2P';

  @override
  String get routeP2PFallback => 'P2P + relay fallback';

  @override
  String get routeRelay => 'relay';

  @override
  String get messageReply => 'Odpowiedz';

  @override
  String get messageCopy => 'Kopiuj wiadomość';

  @override
  String get messageRetry => 'Spróbuj ponownie';

  @override
  String get messageDeleteLocal => 'Usuń tylko na tym urządzeniu';

  @override
  String get messageRetrying => 'Ponawianie…';

  @override
  String get messageDeleting => 'Usuwanie…';

  @override
  String get messageStateQueued => 'w kolejce';

  @override
  String get messageStateSending => 'wysyłanie…';

  @override
  String get messageStateSent => 'wysłano';

  @override
  String get messageStateDelivered => 'dostarczono';

  @override
  String get messageStateRead => 'odczytano';

  @override
  String get messageStateFailed => 'błąd wysyłania';

  @override
  String get chatStarting => 'Uruchamianie rozmowy…';

  @override
  String get chatLoading => 'Ładowanie rozmowy…';

  @override
  String get chatBack => 'Wróć';

  @override
  String get chatSearchHint => 'Szukaj lokalnie w rozmowie…';

  @override
  String get chatContactViewing => 'Kontakt ma otwartą tę rozmowę';

  @override
  String get chatCloseSearch => 'Zamknij wyszukiwanie';

  @override
  String get chatSearch => 'Szukaj';

  @override
  String get chatOptions => 'Opcje rozmowy';

  @override
  String get chatCopyFingerprint => 'Kopiuj fingerprint';

  @override
  String get chatLoadingOlder => 'Ładowanie starszych wiadomości…';

  @override
  String chatUnseenMessages(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count nowych wiadomości',
      many: '$count nowych wiadomości',
      few: '$count nowe wiadomości',
      one: '1 nowa wiadomość',
      zero: 'Brak nowych wiadomości',
    );
    return '$_temp0';
  }

  @override
  String get chatScrollToBottom => 'Przewiń na dół';

  @override
  String get chatPrivateCommunication => 'Prywatna komunikacja przez Tor';

  @override
  String chatCounts(int contacts, int conversations) {
    return '$contacts kontaktów · $conversations rozmów';
  }

  @override
  String get chatRecentConversations => 'Ostatnie rozmowy';

  @override
  String get chatVerifyContact =>
      'Zweryfikuj tożsamość kontaktu w szczegółach, aby rozpocząć rozmowę.';

  @override
  String chatConversationStarted(String name) {
    return 'To początek rozmowy z $name.';
  }

  @override
  String get chatSecureConnectionStarting =>
      'Nawiązywanie bezpiecznego połączenia';

  @override
  String get chatWaitingForSecureConnection =>
      'Rozmowa oczekuje na bezpieczne połączenie.';

  @override
  String get chatRemoveAttachment => 'Usuń załącznik';

  @override
  String get chatCancelReply => 'Anuluj odpowiedź';

  @override
  String get chatPreparingImages => 'Przygotowywanie obrazów…';

  @override
  String get chatAddImages => 'Dodaj obrazy do wiadomości';

  @override
  String get chatComposeHint => 'Napisz wiadomość…';

  @override
  String get chatNotReady => 'Rozmowa nie jest jeszcze gotowa';

  @override
  String get statusTransportConnected => 'Połączono z relayem przez Tor';

  @override
  String get statusTransportStarting => 'Uruchamianie Tor';

  @override
  String get statusTransportBootstrapping => 'Uruchamianie obwodu Tor';

  @override
  String get statusTransportConnecting => 'Łączenie z relayem onion';

  @override
  String get statusTransportDegraded => 'Relay działa w trybie ograniczonym';

  @override
  String get statusTransportReconnecting => 'Ponowne łączenie z relayem';

  @override
  String get statusTransportOffline => 'Tor offline';

  @override
  String get statusTransportError => 'Sprawdzanie połączenia Tor';

  @override
  String get statusComponentEngine => 'Silnik aplikacji';

  @override
  String get statusComponentLocalData => 'Dane lokalne';

  @override
  String get statusComponentTor => 'Sieć Tor';

  @override
  String get statusComponentRelay => 'Relay TorChat';

  @override
  String get statusComponentPeerListener => 'Lokalny listener P2P';

  @override
  String get statusComponentOnionService => 'Onion tego urządzenia';

  @override
  String get statusComponentEngineDescription => 'Wspólny silnik komunikatora';

  @override
  String get statusComponentLocalDataDescription =>
      'Tożsamość i zaszyfrowana baza lokalna';

  @override
  String get statusComponentTorDescription =>
      'Proces Tor i lokalny endpoint SOCKS';

  @override
  String get statusComponentRelayDescription =>
      'Połączenie sterujące z relayem onion';

  @override
  String get statusComponentPeerListenerDescription =>
      'Lokalny serwer przyjmujący połączenia peer';

  @override
  String get statusComponentOnionServiceDescription =>
      'Adres onion publikowany dla tego urządzenia';

  @override
  String get desktopChats => 'Czaty';

  @override
  String desktopConversationCount(int count) {
    return '$count rozmów';
  }

  @override
  String get desktopSearch => 'Szukaj…';

  @override
  String get desktopNoConversations => 'Nie masz jeszcze rozmów.';

  @override
  String get desktopNoConversationMatches =>
      'Brak rozmów pasujących do wyszukiwania.';

  @override
  String get desktopContacts => 'Kontakty';

  @override
  String get desktopFilteredContactsEmpty =>
      'Brak kontaktów dla wybranego filtra.';

  @override
  String desktopContactCount(int count) {
    return '$count zapisanych';
  }

  @override
  String get desktopSearchContacts => 'Szukaj kontaktów…';

  @override
  String get desktopAll => 'Wszyscy';

  @override
  String get desktopOnline => 'Online';

  @override
  String get commonYes => 'Tak';

  @override
  String get commonNo => 'Nie';

  @override
  String get desktopContactDetails => 'Szczegóły kontaktu';

  @override
  String get desktopCloseDetails => 'Zamknij szczegóły';

  @override
  String get desktopContactSection => 'KONTAKT';

  @override
  String get desktopIdentityVerified => 'Tożsamość zweryfikowana';

  @override
  String get desktopIdentityUnverified => 'Tożsamość niezweryfikowana';

  @override
  String get desktopVerifyIdentity => 'Zweryfikuj tożsamość';

  @override
  String get desktopPresenceSection => 'OBECNOŚĆ';

  @override
  String get desktopStatus => 'Status';

  @override
  String get desktopLastSeen => 'Ostatnio widziany';

  @override
  String get desktopObserved => 'Obserwowany';

  @override
  String get desktopObservationExpiry => 'Ważność obserwacji';

  @override
  String get desktopConversationFocus => 'Fokus rozmowy';

  @override
  String get desktopConnectionSection => 'POŁĄCZENIE';

  @override
  String get desktopP2pConnection => 'Połączenie P2P';

  @override
  String get desktopProbeLatency => 'Opóźnienie probe';

  @override
  String get desktopNextProbe => 'Następny probe';

  @override
  String get desktopLastP2pConnection => 'Ostatnie połączenie P2P';

  @override
  String get desktopRoute => 'Trasa';

  @override
  String get desktopEndpoint => 'Endpoint';

  @override
  String get desktopPolicy => 'Polityka';

  @override
  String get desktopInformationSection => 'INFORMACJE';

  @override
  String get desktopInstallationId => 'Installation ID';

  @override
  String get desktopLastP2p => 'Ostatnie P2P';

  @override
  String get desktopBackToConversations => 'Wróć do listy rozmów';

  @override
  String get statusProbeEngine => 'Silnik';

  @override
  String get statusProbeRelay => 'Tor relay';

  @override
  String get statusProbePeer => 'Tor P2P';

  @override
  String get startupEngine => 'Wspólny silnik';

  @override
  String get startupLocalData => 'Dane lokalne';

  @override
  String get startupTor => 'Sieć Tor';

  @override
  String get startupPeerListener => 'Lokalny serwer P2P';

  @override
  String get startupOnionService => 'Usługa onion P2P';

  @override
  String get startupRelay => 'Tor relay';

  @override
  String get startupCommunication => 'Gotowość komunikacji';

  @override
  String get startupEngineDescription => 'Uruchamianie wspólnego silnika Rust';

  @override
  String get startupLocalDataDescription =>
      'Otwieranie zaszyfrowanej bazy i tożsamości';

  @override
  String get startupTorDescription =>
      'Uruchamianie procesu Tor i przygotowanie SOCKS';

  @override
  String get startupPeerListenerDescription =>
      'Nasłuchiwanie lokalnego serwera peer';

  @override
  String get startupOnionServiceDescription =>
      'Publikowanie adresu urządzenia w Tor';

  @override
  String get startupRelayDescription => 'Połączenie z serwerem sterującym';

  @override
  String get startupCommunicationDescription =>
      'Kolejki i odbieranie wiadomości';

  @override
  String contactSemantics(String name) {
    return 'Kontakt $name';
  }

  @override
  String get contactSemanticsHint =>
      'Naciśnij, aby rozpocząć rozmowę. Przytrzymaj, aby otworzyć menu.';

  @override
  String get contactStartConversation => 'Rozpocznij rozmowę';

  @override
  String get contactEnableNotifications => 'Włącz powiadomienia';

  @override
  String get contactMute => 'Wycisz kontakt';

  @override
  String get contactCopyFingerprint => 'Kopiuj fingerprint';

  @override
  String get contactEndRelationship => 'Zakończ relację';

  @override
  String get conversationsLoading => 'Ładowanie rozmów…';

  @override
  String get conversationRename => 'Zmień nazwę lokalną';

  @override
  String get conversationUnpin => 'Odepnij';

  @override
  String get conversationPin => 'Przypnij';

  @override
  String get conversationEnableNotifications => 'Włącz powiadomienia';

  @override
  String get conversationMute => 'Wycisz';

  @override
  String get conversationClearHistory => 'Wyczyść lokalną historię';

  @override
  String get conversationArchive => 'Archiwizuj lokalnie';

  @override
  String get conversationLocalName => 'Lokalna nazwa rozmowy';

  @override
  String get conversationName => 'Nazwa';

  @override
  String get conversationNameLocalOnly =>
      'Nazwa pozostaje tylko na tym urządzeniu.';

  @override
  String get commonCancel => 'Anuluj';

  @override
  String get commonSave => 'Zapisz';

  @override
  String get commonCopy => 'Kopiuj';

  @override
  String get conversationRestore => 'Przywróć';

  @override
  String get conversationClearHistoryTitle => 'Wyczyścić lokalną historię?';

  @override
  String get conversationClearHistoryDescription =>
      'Wiadomości zostaną usunięte wyłącznie z tego urządzenia. Kontakt nie otrzyma informacji o tej operacji.';

  @override
  String get conversationClear => 'Wyczyść';

  @override
  String get conversationHistoryCleared =>
      'Lokalna historia została wyczyszczona.';

  @override
  String get problemPairingWelcomeStale =>
      'Tego zaproszenia nie można już dokończyć. Poproś kontakt o wygenerowanie nowego kodu parowania.';

  @override
  String get problemPairingCodeInvalid =>
      'Kod parowania jest nieprawidłowy albo wygasł. Poproś kontakt o nowy kod.';

  @override
  String get problemPairingRequiresRelay =>
      'Parowanie wymaga dostępnego relay; dane lokalne pozostają dostępne offline.';

  @override
  String get problemNicknameRequired =>
      'Najpierw ustaw nazwę użytkownika na tym urządzeniu.';

  @override
  String get problemInviteCodeUnavailable =>
      'Relay nie zwrócił kodu zaproszenia. Spróbuj ponownie.';

  @override
  String get problemPairingGatewayUnavailable =>
      'Usługa parowania jest chwilowo niedostępna. Spróbuj ponownie za chwilę.';

  @override
  String get problemSecureConnectionPending =>
      'Bezpieczne połączenie nie jest jeszcze gotowe.';

  @override
  String get problemConnectionUnavailable =>
      'Połączenie jest chwilowo niedostępne.';

  @override
  String get problemOperationFailed => 'Nie udało się wykonać operacji.';

  @override
  String get paletteArcade => 'Arcade';

  @override
  String get paletteMocha => 'Mocha';

  @override
  String get paletteGruvbox => 'Gruvbox';

  @override
  String get paletteNord => 'Nord';

  @override
  String get shellAccount => 'Konto';

  @override
  String get shellSettings => 'Ustawienia';

  @override
  String get contactsLocalAlias => 'Lokalny alias';

  @override
  String get contactsSaving => 'Zapisywanie…';

  @override
  String get commonClose => 'Zamknij';

  @override
  String get relationshipEndTitle => 'Zakończyć relację?';

  @override
  String relationshipEndDescription(String name) {
    return 'Kontakt $name utraci możliwość wysyłania wiadomości. Ponowne dodanie będzie wymagało nowego kodu.';
  }

  @override
  String get relationshipKeepHistory => 'Zachowaj historię na tym urządzeniu';

  @override
  String get relationshipKeepHistoryDescription =>
      'Historia pozostanie lokalna i nie przywróci relacji.';

  @override
  String get imageDownload => 'Pobierz obraz';

  @override
  String get imageSaveToGallery => 'Zapisz w galerii';

  @override
  String get imageRemoveFromCache => 'Usuń z zaszyfrowanego cache';

  @override
  String get commonRetry => 'Spróbuj ponownie';

  @override
  String get commonDeleteLocal => 'Usuń tylko na tym urządzeniu';

  @override
  String get connectionDiagnosticsCopied => 'Diagnostyka skopiowana.';

  @override
  String get connectionCopyDiagnostics => 'Kopiuj diagnostykę';

  @override
  String get connectionRetry => 'Ponów połączenie';

  @override
  String get connectionRetrying => 'Ponawianie…';

  @override
  String get commonContact => 'Kontakt';

  @override
  String get commonImage => 'Obraz';

  @override
  String get chatWaitingForMessage => 'Oczekiwanie na wiadomość';

  @override
  String get contactsRotate => 'Rotuj';

  @override
  String get contactsRevoke => 'Unieważnij';

  @override
  String get contactsNoDeadLetters => 'Brak dead-letterów';

  @override
  String get contactsDeadLetterRetry => 'Ponawianie dead-letterów';

  @override
  String get contactsNoError => 'Brak błędu';

  @override
  String get contactsSavingSettings => 'Zapisywanie ustawień…';

  @override
  String get contactsEstablishedByPairingCode =>
      'Relacja ustanowiona przez zaakceptowany kod';

  @override
  String get contactsP2pThroughTor => 'P2P przez Tor';

  @override
  String get contactsDirectConnection => 'Połączenie bezpośrednie';

  @override
  String get contactsCurrentRoute => 'Aktualna trasa';

  @override
  String get contactsPresence => 'Obecność';

  @override
  String get contactsViewingConversation => 'Ogląda rozmowę';

  @override
  String get contactsLastProbe => 'Ostatni probe';

  @override
  String get contactsNoData => 'brak danych';

  @override
  String get contactsProbeLatency => 'Latency probe';

  @override
  String get contactsP2pCapability => 'Capability endpointu P2P';

  @override
  String get contactsCapabilityUnavailable => 'Status capability niedostępny';

  @override
  String get contactRouteRelay => 'relay';

  @override
  String get contactRouteP2pOnion => 'P2P onion';

  @override
  String get contactRouteRelayFallback =>
      'live relay fallback (P2P nieaktywne)';

  @override
  String get contactRouteP2pOffline => 'P2P oczekuje / offline';

  @override
  String get contactEndpointVerified => 'endpoint zweryfikowany';

  @override
  String get contactEndpointPending => 'oczekuje na wymianę endpointu';

  @override
  String get contactEndpointInvalid => 'endpoint nieprawidłowy';

  @override
  String get contactEndpointMissing => 'endpoint niedostępny';

  @override
  String get contactAvailabilityActive => 'aktywny w aplikacji';

  @override
  String get contactAvailabilityIdle => 'bezczynny';

  @override
  String get contactAvailabilityChecking => 'sprawdzanie';

  @override
  String get contactAvailabilityOffline => 'offline';

  @override
  String get contactAvailabilityUnknown => 'status nieznany';

  @override
  String get contactPeerConnected => 'połączono';

  @override
  String get contactPeerConnecting => 'łączenie';

  @override
  String get contactPeerAuthenticating => 'uwierzytelnianie';

  @override
  String get contactPeerBackoff => 'oczekiwanie na ponowienie';

  @override
  String get contactPeerOffline => 'offline';

  @override
  String get contactPeerUnknown => 'nieznany';

  @override
  String get contactPolicyP2pOnly => 'Tylko P2P';

  @override
  String get contactPolicyFallback => 'P2P + live relay fallback';

  @override
  String get contactsNewContact => 'Nowy kontakt';

  @override
  String get contactsWaitingForSecureConversation =>
      'Oczekiwanie na ustanowienie szyfrowanej rozmowy';

  @override
  String get contactsTransportPolicy => 'Polityka transportu';

  @override
  String get onboardingNicknameLabel => 'Nick';

  @override
  String get onboardingSaveNickname => 'Zapisz nick';

  @override
  String get appTagline => 'Prywatne wiadomości przez Tor';

  @override
  String get timeJustNow => 'przed chwilą';

  @override
  String timeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min temu',
      many: '$count minut temu',
      few: '$count minuty temu',
      one: 'minutę temu',
    );
    return '$_temp0';
  }

  @override
  String timeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count godz. temu',
      many: '$count godzin temu',
      few: '$count godziny temu',
      one: 'godzinę temu',
    );
    return '$_temp0';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dni temu',
      many: '$count dni temu',
      few: '$count dni temu',
      one: 'wczoraj',
    );
    return '$_temp0';
  }
}
