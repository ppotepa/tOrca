## THEME.MD — Flutter UI + notification UX runbook (Android)

Zakres: Flutter `mobile` + Android notification bridge.  
Nie ruszamy protocol/runtime transport/state machine.
Nie uruchamiamy pełnych testów; używamy tylko krótkich sanity checków.

Format działania:  
przed każdym krokiem -> RTK status + diff; podczas kroku -> CodeGraph + `rg`; po kroku -> RTK status + lokalne sprawdzenie.

### 0) Startowy setup

```powershell
rtk git status --short
rtk git diff --stat
codegraph status .
```

Jeśli CodeGraph jest niestabilny, najpierw:

```powershell
codegraph sync
```

Akcept:
- wiemy, czy jesteśmy w tym samym punkcie co poprzedni agent
- nie tracimy zmian roboczych.

### 1) Inwentaryzacja ścieżek UI/kontraktów

```powershell
codegraph query "ConversationListTile"
codegraph query "PairingRecordCard"
codegraph query "InboxView"
codegraph query "MainShell"
codegraph query "notifyIncoming"
codegraph query "RuntimeContract.NOTIFY_INCOMING"
codegraph query "RuntimeContract.inviteReceived"
codegraph query "RuntimeContract.messageReceived"
```

```powershell
rg -n "ConversationListTile|PairingRecordCard|PairingListSection|CounterBadge|activeInviteCount|unread|notifyIncoming|NOTIFY_INCOMING|lastSeen|lastMessageAt|Theme\\.of\\(context\\)|withValues\\(|Text\\(" mobile/lib -g '*.dart'
rg -n "notifyIncoming|NOTIFY_INCOMING|notifyIncomingNotification|RuntimeContract.NOTIFY_INCOMING|MethodChannel" mobile/lib mobile/android/app/src/main/kotlin -g '*.dart' -g '*.kt'
```

Akcept:
- mamy pełną listę miejsc do zmiany; brak duplikowania logiki biznesowej.

### 2) Kontrakt tokenów motywu shell + inbox

Pliki:
- `mobile/lib/app/theme/extensions/torchat_shell_theme.dart`
- `mobile/lib/app/theme/extensions/torchat_inbox_theme.dart`
- `mobile/lib/app/theme/extensions/torchat_chat_theme.dart`
- `mobile/lib/app/theme/families/current_theme.dart`
- `mobile/lib/app/theme/families/retro_theme.dart`

```powershell
codegraph query "TorChatShellTheme"
codegraph query "TorChatInboxTheme"
codegraph query "TorChatChatTheme"
rg -n "listItemRadius|listItemBorderWidth|actionMinWidth|actionMinHeight|actionPaddingHorizontal|actionIconSize|bubbleRadius|bubbleBorderWidth|actionRadius|cardRadius" mobile/lib/app/theme -g '*.dart'
```

Akcje:
1. Potwierdź, że `TorChatShellTheme` ma:
   - `listItemRadius`
   - `listItemBorderWidth`
2. Potwierdź, że `TorChatInboxTheme` ma:
   - `actionRadius`, `cardRadius`, `cardBorderWidth`
   - `actionMinWidth`, `actionMinHeight`, `actionPaddingHorizontal`, `actionIconSize`
3. W `current_theme.dart` i `retro_theme.dart` sprawdź kompletność obu wariantów:
   - light / dark
   - te same pola ustawione jawnie.
4. Retro:
   - `fontFamily` = monospace lub docelowy retro font
   - mocniejsze obrysy i wyraźniejsze promienie.

Akcept:
- brak brakujących pól przy budowie `ThemeData`.

### 3) Wydobycie styli listy rozmów (conversation list)

Pliki:
- `mobile/lib/shared/widgets/list_items.dart`
- `mobile/lib/shared/widgets/conversation_list_section.dart`
- `mobile/lib/features/chats/chats_view.dart` (ewentualne marginesy)
- `mobile/lib/app/theme/extensions/torchat_chat_theme.dart` (opcjonalnie nowe tokeny listy)

```powershell
codegraph query "ConversationListSection"
codegraph query "ConversationListTile"
rg -n "ListTile\\(|RoundedRectangleBorder|unreadBackground|unreadBorder|tileColor|titleMedium|labelSmall|fontSize|SizedBox\\(height:|FontWeight" mobile/lib/shared/widgets mobile/lib/features/chats -g '*.dart'
```

Akcje:
1. `ConversationListTile` używa tylko `context.shellTheme` i `context.chatTheme`.
2. Parametry obwódki / corner radius biorą się z theme.
3. Podświetlenie rozmów:
   - `hasUnread` -> inny `tileColor`
   - `CounterBadge` w wierszu.
4. Ujednolić wysokość i spacingi (np. `lastSeen` jako druga linia).

Akcept:
- brak `BorderRadius.circular(...)` lub `SizedBox` z rozmiarem listy hardcoded w tym widżecie.

### 4) Inbox UX: większe akcje + klarowne gesty

Pliki:
- `mobile/lib/features/inbox/inbox_view.dart`
- `mobile/lib/shared/widgets/pairing_cards.dart`
- `mobile/lib/shared/widgets/pairing_list_section.dart`
- `mobile/lib/app/theme/extensions/torchat_inbox_theme.dart`

```powershell
codegraph query "PairingAvailableAction"
codegraph query "PairingRecordCard"
rg -n "minimumSize|OutlinedButton|FilledButton|TextButton.icon|Dismissible|Swipe|startToEnd|endToStart|archive|accept|reject" mobile/lib/features/inbox mobile/lib/shared/widgets -g '*.dart'
```

Akcje:
1. Zachowaj kierunek:
   - `startToEnd` -> odrzucenie / archiwum
   - `endToStart` -> akcept / archiwum
2. Zamiast wartości stałych użyć tokenów:
   - `actionMinWidth`, `actionMinHeight`, `actionPaddingHorizontal`, `actionIconSize`
3. Akcept/odrzuć jako duże cele dotykowe (56–64 px wysokość).
4. Swipe background:
   - szerokość na szerokość wiersza, stały `height` z tokena.
5. `outbox`:
   - zachować przyciski anulowania i archiwizacji jako spójne style.

Akcept:
- action buttons i swipe są czytelne bez skalowania ekranu.

### 5) Powiadomienia i dźwięk (Android)

Pliki:
- `mobile/lib/app/app_controller.dart`
- `mobile/lib/core/runtime/runtime_contract.dart`
- `mobile/android/app/src/main/kotlin/org/torchat/mobile/RuntimeContract.kt`
- `mobile/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt`
- `mobile/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt`

```powershell
codegraph query "RuntimeContract.notifyIncoming"
codegraph query "_notifyIncoming"
codegraph query "notifyIncomingNotification"
rg -n "kind|payload|MethodChannel\\(|notifyIncoming\\(|NOTIFY_INCOMING|alertIncoming|notificationId" mobile/lib mobile/android/app/src/main/kotlin -g '*.dart' -g '*.kt'
```

Akcje:
1. `AppController`:
   - nadal wyzwala `_notifyIncoming` tylko dla `invite`/`message`.
   - wysyła `payload` (np. nazwa peer + status/invite id + skrót).
2. `MainActivity.kt`:
   - sprawdza `payload` z `MethodCall`.
   - przekazuje do `TorChatForegroundService.notifyIncoming(context, kind, payload)`.
3. `TorChatForegroundService.notifyIncomingNotification`:
   - kanał ALERT + HIGH + dźwięk + wibracja + `autoCancel`.
   - stabilny `notificationId` na bazie hash payloada/kind.
4. Unikaj dublowania: tylko jedno wejście do notyfikacji per incoming event.

Akcept:
- nowa wiadomość + invite => idzie notification + alert audio.

### 6) Unread badge + podświetlenie zakładek

Pliki:
- `mobile/lib/features/shell/main_shell.dart`
- `mobile/lib/shared/widgets/counter_badge.dart`
- `mobile/lib/shared/widgets/list_items.dart`

```powershell
codegraph query "activeInviteCount"
codegraph query "totalUnread"
rg -n "counter|badge|_InboxNavIcon|unreadTotal|inboxTotal|CounterBadge\\(" mobile/lib/features/shell mobile/lib/shared -g '*.dart'
```

Akcje:
1. `MainShell` i `DesktopMainShell` powinny pokazywać:
   - licznik czatów (unreadTotal)
   - licznik inbox (activeInviteCount)
2. W listach:
   - odróżnienie wizualne nieprzeczytanych (color/weight/badge).
3. Po odbiorze i odświeżeniu danych:
   - stan `unread` nie może być pomijany.

Akcept:
- widoczny stan pending dla co najmniej jednego nowego eventu.

### 7) Last seen / aktywność kontaktu

Pliki:
- `mobile/lib/shared/widgets/conversation_list_section.dart`
- `mobile/lib/shared/widgets/list_items.dart`
- `mobile/lib/shared/formatters/conversation_display.dart` (jeśli tam jest format czasu)
- `mobile/lib/features/chats/chats_view.dart`

```powershell
codegraph query "conversationLastSeenLabel"
codegraph query "lastMessageAt"
rg -n "lastSeen|lastMessageAt|formatMessageTime|formatter|last activity|presence|lastMessage" mobile/lib/shared mobile/lib/features -g '*.dart'
```

Akcje:
1. W `ConversationListTile`:
   - `lastMessageAt` + `lastSeen` jako maks. 2 linie.
2. Zachować spójny układ dla desktop/mobile.
3. Minimalna typografia: drugi wiersz `fontSize ~11`.

Akcept:
- „lastSeen” nie zaburza wysokości karty i nie przesuwa badge.

### 8) Retro jako drugi motyw (current/retro i light/dark)

Pliki:
- `mobile/lib/app/theme/families/retro_theme.dart`
- `mobile/lib/app/theme/theme_registry.dart`
- `mobile/lib/app/theme/theme_preferences.dart`
- `mobile/lib/app/app_theme.dart`
- `mobile/pubspec.yaml` (font assets, jeśli dodajesz nowy font)

```powershell
codegraph query "buildRetroLightTheme"
codegraph query "buildRetroDarkTheme"
codegraph query "buildCurrentLightTheme"
codegraph query "buildCurrentDarkTheme"
```

```powershell
rg -n "monospace|fontFamily|scanlines|pixelated|alertGlow|bubbleRadius|listItemRadius|borderWidth|selectedNavigation" mobile/lib/app/theme mobile/lib -g '*.dart'
```

Akcje:
1. `buildRetroLightTheme` / `buildRetroDarkTheme` powinny:
   - mieć komplet tych samych extensionów co `current`.
2. Zdefiniować rodzinę motywu jako osobny przypadek w `theme_preferences`.
3. Dodać `Font` dla retro, jeśli potrzebny:
   - asset w `mobile/assets/fonts/...`
   - deklaracja w `pubspec.yaml`.

Akcept:
- przełącznik rodziny działa na obu stronach jasna/ciemna bez regresji kompilacji.

### 9) Finalny cleanup UI hardcoded

Pliki:
- `mobile/lib/features/*`
- `mobile/lib/shared/widgets/*`

```powershell
rg -n "0x[0-9A-Fa-f]{8}|fontSize:\\s*\\d{2}|EdgeInsets\\.fromLTRB\\(|EdgeInsets\\.only\\(|BorderRadius\\.circular\\(|FontWeight\\.w700|withOpacity|withAlpha|SizedBox\\.square\\(" mobile/lib/features mobile/lib/shared -g '*.dart'
```

Akcje:
1. Zamień kolejne liczby na tokeny tam, gdzie dotyczą UI systematycznie.
2. Pozostań w wyjątkach tylko tam, gdzie to element treściowy (np. ikony).
3. Przejdź przez `dart format`.

### 10) Sanity check po każdej iteracji (bez testów)

```powershell
dart format mobile/lib/app/theme mobile/lib/features mobile/lib/shared mobile/lib
rtk git status --short
rtk git diff --stat
codegraph query "ConversationListTile"
codegraph query "PairingRecordCard"
```

Opcjonalnie przy buildzie:

```powershell
rtk flutter analyze mobile/lib
```

### Kolejność wykonywania (strict)
1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10

Nie ruszamy:
- protokołu transportu
- trwałego lifecycle wiadomości (runtime)
- logiki backendu serwera

