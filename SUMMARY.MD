# TorChat Refactor Summary

Last updated: 2026-07-29
Branch: `agent/common-runtime-cleanup`

## Goal

Domknac refactor zgodnie z `REFACTOR2.MD` i `AGENTS.md`: aktywne legacy sciezki maja zniknac, a Android, desktop, Flutter i Rust maja korzystac z jednego kontraktu engine generowanego z `common/client-engine-contract.json`.

## Final Status

Status ogolny: domkniete i zweryfikowane lokalnie.

Przechodzi lokalnie:

- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\check-runtime-contract.ps1`
- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\check-legacy-cleanup.ps1`
- [x] `cargo test -p torchat-client-runtime`
- [x] `cargo test -p torchat-client-engine storage::sqlite::tests`
- [x] `cargo test -p torchat-client-engine-ffi c_api::tests`
- [x] `cargo check -p torchat-client-engine -p torchat-desktop`
- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\build-android-core.ps1`
- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\build-desktop-runtime.ps1 -Release`
- [x] `flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart`
- [x] `.\gradlew.bat :app:compileDebugKotlin` z katalogu `mobile\android`
- [x] Build warning cleanup:
  - `cargo check -p torchat-client-engine -p torchat-desktop` bez warningow
  - `cargo test -p torchat-client-runtime` bez warningow
- [x] `rg -n "RuntimeRequest|RuntimeResponse|dispatch_runtime|map_runtime_request|response_to_runtime_response" desktop mobile common`
- [x] `rg -n '"type", "[a-z_]+"|put\("type", "[a-z_]+"|''method'': method|''params'': params' mobile desktop common`

Uwaga srodowiskowa:

- [x] Zainstalowany `Strawberry Perl`, wymagany przez lokalny Windows build `openssl-sys`.
- [x] Zainstalowany `MSYS2` + `make`, wymagany przez Android cross-build vendored OpenSSL/SQLCipher.

## Closed Items

- [x] Stary publiczny runtime contract usuniety:
  - `common/client-runtime-contract.json`
  - `common/client-runtime-scenarios.json`
  - `common/client-runtime-fixtures.json`
- [x] Fixture runtime przeniesione do internal:
  - `common/internal-runtime-fixtures.json`
- [x] Stare C ABI runtime usuniete:
  - `common/torchat-client-runtime/src/c_api.rs`
- [x] Stare testy publicznej granicy runtime usuniete:
  - `common/torchat-client-runtime/tests/contract_manifest.rs`
  - `common/torchat-client-runtime/tests/scenarios.rs`
  - `common/torchat-client-runtime/tests/support/mod.rs`
  - `mobile/test/runtime_scenario_projection_test.dart`
- [x] Android/Flutter/desktop przestawione na engine envelope i engine contract.
- [x] Contract checker sprawdza wygenerowane Rust/Kotlin/Dart symbole engine.
- [x] Legacy checker sprawdza usuniete artefakty i aktywne legacy symbole.
- [x] Android compile naprawiony po bledzie nullable `EventSink` w `MainActivity.kt`.
- [x] Runtime rule poprawiona: `promote_contact()` ustawia rozmowe na `VERIFYING`, gdy kontakt nie jest zweryfikowany.
- [x] Runtime test poprawiony pod faktyczna regule read reset: po `open_conversation()`, `close_conversation()` i nowej wiadomosci unread wynosi `1`, nie stara wartosc plus jeden.
- [x] Dodane i zweryfikowane testy SQLite/SQLCipher w `common/torchat-client-engine/src/storage/sqlite.rs`.
- [x] Dodane i zweryfikowane testy lifecycle C ABI w `common/torchat-client-engine-ffi/src/c_api.rs`.
- [x] Naprawiony bootstrap migracji pustej bazy w `common/torchat-client-engine/src/storage/migrations.rs`.
- [x] Naprawiony testowy config FFI pod walidacje exact onion URL bez portu.
- [x] Dodana brakujaca zaleznosc `base64` w `desktop/Cargo.toml`.
- [x] Udostepnione transakcyjne API `RuntimeSession` dla wspolpracy runtime/engine.
- [x] Naprawiony `scripts/internal/build-android-core.ps1`, zeby Android Rust build uzywal MSYS2 Perl/make oraz recznie ustawionego NDK toolchain z forward-slash sciezkami.
- [x] Naprawiony `scripts/internal/build-desktop-runtime.ps1`, zeby desktop/MSVC wymuszal natywnego Windows Perla i nie lapal MSYS2/Cygwin Perla z aktualnego `PATH`.
- [x] Usuniety warning `dead_code` z desktop przez skasowanie nieuzywanego `identity_store::load_existing`.
- [x] Usuniete warningi Cargo o hardlinkach incremental przez repo-local `.cargo/config.toml` z `incremental = false`.
- [x] Dodane ignorowanie Gradle/Kotlin cache `.kotlin/`.
- [x] Dodany smart incremental build cache:
  - `scripts/torchat.ps1 build-clients -Incremental`
  - `scripts/torchat.ps1 full-deploy -Incremental`
  - `scripts/torchat.ps1 redeploy -Incremental`
- [x] `redeploy -Incremental` zachowuje obecny onion i lokalne wolumeny, dzieki czemu bez zmian robi szybka podgrywke i start zamiast destrukcyjnego rebuilda.
- [x] `build-clients -Incremental` nie przebudowuje ani nie odtwarza juz
  kontenerow serwera/Tora. Usunieto odwrocona logike `start-dev.ps1`, ktora
  dodawala `docker compose up --build`, gdy `-Rebuild` nie byl ustawiony.
  Build bez zmian zweryfikowany w `2,05 s`: desktop engine, Android `.so`, APK
  i Windows client zostaly pobrane ze smart-cache.
- [x] Flutter status polaczenia nie pokazuje juz technicznych snapshotow typu `platform fact applied`; surowy `relay transport error` jest mapowany na czytelny komunikat o niedostepnym albo nieaktualnym onion.
- [x] Bledy HTTP relaya zachowuja kategorie domenowe (`InvalidParams`,
  `NotFound`, `Conflict`, `Timeout`) i tresc odpowiedzi serwera zamiast zawsze
  stawac sie technicznym `relay transport error`.
- [x] Przeplyw kontaktow tlumaczy komunikaty relaya dla wygaslego kodu,
  parowania z samym soba, oczekujacego duplikatu, limitu prob i nieaktualnego
  zaproszenia. Test kontrolera odtwarza odpowiedz
  `pairing code expired or invalid`.
- [x] Osobny Inbox/Outbox zostal usuniety z mobilnej i desktopowej nawigacji.
  Inbox/outbox pozostaja wewnetrznym stanem runtime wymaganym przez protokol,
  deduplikacje i handshake MLS, ale nie sa osobnym miejscem zarzadzania w UI.
- [x] Ekran kodu parowania dziala jak autoryzacja BLIK: po wykryciu nowego
  zadania ukrywa QR, pokazuje nick i fingerprint osoby oraz daje 15 sekund na
  `Akceptuj` albo `Odrzuc`. Timeout odrzuca zadanie. Po akceptacji ekran czeka
  na faktyczne pojawienie sie kontaktu utworzonego przez runtime zamiast
  oglaszac sukces po samym wyslaniu oferty MLS.
- [x] Trasy relaya uzywane przez klienta zostaly porownane z routerem serwera:
  wszystkie 8 endpointow HTTP i `/v1/events` WebSocket maja zgodne metody oraz
  sciezki. Obserwowany `404 /v1/pairing-requests` byl odpowiedzia domenowa dla
  wygaslego lub nieprawidlowego kodu, nie brakiem endpointu.
- [x] Android `TorRuntime.start()` czeka na udany SOCKS5 CONNECT do onion
  skompilowanego w `BuildConfig.TORCHAT_SERVER_URL`, zamiast uznawac sam
  lokalny port SOCKS za gotowy obwod.
- [x] Android przekazuje engine `socks5h://`, wiec hostname `.onion` jest
  rozwiazywany przez Tor. Przejsciowy blad relay uruchamia backoff bez
  zatrzymywania engine i natywnej uslugi Tor.
- [x] Desktop `runtime_engine_stdio::relay_url()` korzysta z
  `TORCHAT_COMPILED_ONION_URL`, gdy nie podano jawnego runtime override.
  Destrukcyjny redeploy generuje onion przed buildem, a adres jest osadzany w
  Android APK i desktopowym sidecarze; zmiana onion uniewaznia oba smart-cache.
- [x] CodeGraph zsynchronizowany po zmianach.
- [x] Naprawione trzy bledy blokujace przeplyw kontaktow wykryte w logach:
  - desktopowe `list_conversations` odczytuje aliasy
    `last_message_preview` i `last_message_at`, zamiast pytac rusqlite o nazwy
    niewystepujace w wyniku zapytania;
  - serwer uruchamia migracje `007_contacts.sql`, ktora tworzy brakujaca
    tabele metadanych kontaktow bez przechowywania wiadomosci lub MLS;
  - `build_contact_invite()` zapisuje snapshot MLS po wygenerowaniu
    `KeyPackage`, dzieki czemu restart klienta nie usuwa klucza potrzebnego do
    obslugi pozniejszego `Welcome`.
- [x] Po poprawkach przebudowano serwer, desktop engine, Android engine, APK i
  Flutter Windows. APK wdrozono, desktop uruchomiono, a oba klienty korzystaja
  z onion `rhps2s6i57t4np6ib75qlazzvvqkmomkvq6n2x6wyse3tjkia2ggogid.onion`.
- [x] Logi po wdrozeniu potwierdzaja gotowy obwod Android Tor i zarejestrowana
  sesje WebSocket. Nie pojawily sie nowe `404`, `Invalid column name`,
  `relation "contacts" does not exist` ani `No matching key package`.
- [x] Pierwsze udane przejscie statusu Tor do `connected` odtwarza jednorazowo
  `assets/audio/intro.mp3` na Androidzie i Windows. Flutter wyzwala wspolny
  kanal `org.torchat/audio`; Android korzysta z `MediaPlayer`, a Windows z MCI.
  Blad opcjonalnego audio nie zmienia poprawnego statusu polaczenia.
- [x] Retro zachowuje stale role semantyczne `success`, `warning`, `danger`
  i `info`, ale kazda paleta moze stosowac wlasny, zblizony odcien. Status Tor,
  wysylane wiadomosci, alerty i unread nadal korzystaja z tych samych rol.
- [x] Retro ma cztery zapisywane palety terminalowe: `Arcade`, domyslna ciemna
  `Mocha`, `Gruvbox` i `Nord`, kazda ze spojnym wariantem jasnym i ciemnym.
  Zmiana palety jest widoczna natychmiast bez ponownego otwierania ustawien.
- [x] Kontrakt geometrii Retro jest prostokatny dla kart, inputow, chipow,
  dialogow, snackbarow, segmented buttons, przyciskow, nawigacji, badge'y,
  separatorow daty, awatarow i przelacznikow. Retro switch ma prostokatny tor
  i kwadratowy suwak; Classic nadal uzywa kontrolki Material.
- [x] Composer zajmuje cala szerokosc aktywnego panelu czatu bez podwojnego
  bocznego paddingu. `FeatureHeader` zajmuje cala szerokosc i przy waskim
  ekranie przenosi akcje pod tytul zamiast powodowac sciskanie lub overflow.
- [x] `theme_contract_test.dart` pilnuje rol kolorystycznych wszystkich palet,
  prostokatnej geometrii, switcha Retro i selektora ustawien przy 400 px.
- [x] Dodany niezalezny zestaw ikon `pixelarticons` i centralny `ThemedIcon`.
  Classic zachowuje Material Icons, a Retro mapuje te same role na pikselowe
  glify dla nawigacji, czatow, kontaktow, pairing, onboardingu, konta,
  ustawien i skanera. Test pilnuje zmiany rodziny glifu bez zmiany znaczenia.
- [x] Composer obsluguje `Enter` jako wyslanie oraz `Shift+Enter` jako jawne
  wstawienie nowej linii z poprawnym zachowaniem zaznaczenia. Pokrywa to osobny
  test widgetowy.
- [x] Dodane lokalne wyszukiwanie w aktualnie odszyfrowanej rozmowie oraz menu
  dlugiego przytrzymania/prawego przycisku z kopiowaniem wiadomosci.
- [x] Fingerprint pairing jest schowany w rozwijanych szczegolach
  bezpieczenstwa, a szczegoly zapisanego kontaktu pokazuja nick, weryfikacje,
  installation ID i kopiowalny fingerprint.
- [x] Ustawienia zawieraja powiadomienia, dzwiek, wibracje, prywatny podglad,
  alerty pairing, read receipts, typing i status online. Android respektuje
  ustawienia powiadomien takze w tle, Windows respektuje globalny dzwiek.
  Dzwiek intro polaczenia Tor pozostaje niezalezny i bez zmian.
- [x] Usuniety mylacy `last seen` wyliczany z czasu ostatniej wiadomosci.
- [x] Dodane kanoniczne komendy runtime `retryMessage` i
  `deleteMessageLocal`, implementacje storage/engine/Android/desktop/Flutter
  oraz akcje w menu wiadomosci. Kontrakt, Rust, Flutter i Kotlin przechodza
  kontrole kompilacji.
- [x] Dodane odpowiedzi na wiadomosc i rozszerzony kanoniczny payload oraz
  lokalny model/storage o referencje reply.
- [x] Dodane testy runtime pokrywajace dozwolone i odrzucone retry oraz lokalne
  usuniecie wraz z eventem odswiezenia rozmowy.
- [x] Dodane efemeryczne presence/typing i opcjonalne read receipts przez
  wygenerowany kontrakt; relay nie moze utrwalac historii aktywnosci.
- [x] Efemeryczne payloady zachowuja spojny snapshot MLS przy bledzie relay:
  rollback jest wykonywany tylko przed trwalym zapisem, a zapisana generacja
  nie jest cofana wylacznie w pamieci.
- [x] Dodane ustawienia per-contact: alias lokalny, mute i block, egzekwowane
  przed notyfikacja oraz przed wyslaniem/obsluga wiadomosci.
- [x] Naprawiona propagacja nicku podczas parowania: produkcyjny
  `EngineRuntimeTransport::update_profile` wywoluje teraz `PUT /v1/profile`,
  a `connect` ponownie synchronizuje lokalny profil po restarcie relaya.
  Test runtime potwierdza wywolanie transportu.
- [x] Swieze parowanie Android <-> desktop po wdrozeniu zostalo potwierdzone:
  pairing `5fc08c07-e98c-4c6b-9a32-0f1e88880a2c` polaczyl instalacje Android
  `XFeO8Ub-zAHU5j1XII2t4dM1tsL97XfgY3NinmCaAQk` i desktop
  `PQ9ChXQiQbEIADdanl_wVCzrmm1jlrL0sNw47DVnWY8`. UI Android pokazuje kontakt
  `teee1`, a UI desktop kontakt `torca`; oba pokazuja status online i te sama
  rozmowe z wiadomosciami przeslanymi w obu kierunkach.

## Verification Notes

`cargo test -p torchat-client-engine storage::sqlite::tests` wypisuje log SQLCipher przy tescie z blednym kluczem:

```text
sqlcipher_page_cipher: hmac check failed for pgno=1
sqlite3Codec: error decrypting page 1 data: 1
```

To jest oczekiwane i odpowiada testowi `reopen_with_wrong_sqlcipher_key_fails_integrity_check`.

Oba wyszukania `rg` dla legacy request/response i hardcoded command type zakonczyly sie bez trafien produkcyjnych.

Pakiet `.torchat/logs/20260729/run-0039` nie zawiera bledow aplikacji, HTTP
404, panicow ani wyjatkow po parowaniu. Log serwera zawiera utworzenie pairing
`5fc08c07-e98c-4c6b-9a32-0f1e88880a2c` i kolejne koperty relay w obu
kierunkach. Jedynym dopasowaniem ogolnego filtra `error` jest opcja procesu
Tor Browser `ExtendedErrors`, a nie blad TorChat.

Android core jest generowany do
`mobile/build/app/generated/jniLibs/arm64-v8a/libtorchat_client_engine.so`.
Gradle uzywa tego katalogu jako jedynego zrodla bibliotek JNI. Artefakt nie
trafia do `src/main`, nie zanieczyszcza drzewa zrodel i moze byc bezpiecznie
odtwarzany przez smart-cache. Pierwszy run zapisuje cache, a kolejny bez zmian
pomija kompilacje i kopiowanie.

Flutter Windows korzysta ze stalego staging cache pod
`%LOCALAPPDATA%\TorChat\flutter-windows\<hash-repo>`, dzieki czemu kolejne
buildy wykorzystuja cache Flutter/CMake. Dzialajacy klient jest zatrzymywany
dopiero po udanym buildzie, tuz przed kopiowaniem plikow wynikowych. Gdy smart
cache jest swiezy, klient nie jest zatrzymywany.

## Commands Log

Finalnie zaliczone:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\internal\check-runtime-contract.ps1
powershell -ExecutionPolicy Bypass -File scripts\internal\check-legacy-cleanup.ps1
cargo test -p torchat-client-runtime
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo test -p torchat-client-engine storage::sqlite::tests
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo test -p torchat-client-engine-ffi c_api::tests
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo check -p torchat-client-engine -p torchat-desktop
powershell -ExecutionPolicy Bypass -File scripts\internal\build-android-core.ps1
powershell -ExecutionPolicy Bypass -File scripts\internal\build-desktop-runtime.ps1 -Release
flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart
.\gradlew.bat :app:compileDebugKotlin
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo check -p torchat-client-engine -p torchat-desktop
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo test -p torchat-client-runtime
powershell -ExecutionPolicy Bypass -File scripts\internal\build-desktop-runtime.ps1 -Release -SkipIfFresh
flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart
docker compose -f infra\docker-compose.local.yml build server
cargo test -p torchat-client-engine
cargo check -p torchat-server -p torchat-desktop
.\scripts\torchat.ps1 build-clients -Target all -Incremental
.\scripts\torchat.ps1 deploy-mobile
.\scripts\torchat.ps1 run-desktop -SkipEnvironmentStart
.\scripts\torchat.ps1 logs
rtk test cargo test -p torchat-client-engine
flutter analyze
flutter test
.\scripts\torchat.ps1 build-clients -Target all -Incremental
.\scripts\torchat.ps1 deploy-mobile
.\scripts\torchat.ps1 run-desktop -SkipEnvironmentStart
rg -n "RuntimeRequest|RuntimeResponse|dispatch_runtime|map_runtime_request|response_to_runtime_response" desktop mobile common
rg -n '"type", "[a-z_]+"|put\("type", "[a-z_]+"|''method'': method|''params'': params' mobile desktop common
codegraph sync
```

## Exit Criteria

- [x] Wszystkie funkcjonalne punkty z planu w `SUMMARY.MD` sa domkniete.
- [x] Rust engine, Rust FFI, desktop, Flutter i Android maja lokalne potwierdzenie.
- [ ] Biezace zmiany palet i geometrii Retro oczekuja na osobny commit/push.
