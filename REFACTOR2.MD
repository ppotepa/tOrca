# REFACTOR2 - plan domkniecia wspolnego Rust Client Engine

## Status

Pozostalo okolo 35 procent prac z REFACTO1.MD. Engine, FFI, canonical
migrations, relay actor i retry istnieja, ale koncowy cutover nie jest
zakonczony, bo Android nadal ma wlasny SQLCipher store i legacy SQL, Flutter
nadal wystawia adapter-only commands, a desktop nadal zawiera stare moduly.

Ten dokument opisuje kolejnosc, pliki, symbole, operacje i kryteria
akceptacji. REFACTO1.MD nadal definiuje architekture docelowa.

## Zasady wykonania

1. Nie dodawac kodu zgodnosci dla starych baz ani legacy commands.
2. Nie otwierac jednego pliku bazy przez Kotlin SQLCipher i Rust SQLite.
3. Nie przenosic pairing, MLS, retry, relay ani state transitions do hostow.
4. Zmiana publicznego DTO zaczyna sie w Rust i trafia do generowanego kontraktu.
5. Po kazdym etapie uruchomic najmniejszy check dla zmienionej granicy.
6. Usuwac legacy pliki w tym samym etapie, w ktorym ich caller przechodzi na engine.
7. Zachowac publiczne komendy scripts/torchat.ps1 bez dodawania aliasow.

## Kolejnosc zaleznosci

1. SQLCipher i jedyna baza engine.
2. Publiczne read models engine.
3. Android bez Kotlin store, starego runtime i relaya.
4. Generowany kontrakt Rust, Kotlin i Dart.
5. Flutter bez adapter-only API.
6. Desktop bez pozostalych legacy runtime modulow.
7. Build, FFI i artefakty.
8. Testy semantyczne i finalny audit.

Nie zaczynac kroku 3 przed krokiem 2. MainActivity musi najpierw uzyskac
kontakty, rozmowy i wiadomosci przez engine, zanim zostanie usuniety
EncryptedMessageStore.

---

# 1. SQLCipher jako jedyna implementacja bazy

## 1.1 Problem do usuniecia

Plik common/torchat-client-engine/Cargo.toml ma obecnie rusqlite z feature
bundled. To jest zwykly SQLite, nie SQLCipher.

Funkcja ClientDatabase::open w
common/torchat-client-engine/src/storage/sqlite.rs dostaje database_key, ale
obecnie tylko wywoluje database_key.expose() i go nie stosuje.

Android w TorChatForegroundService tworzy EncryptedMessageStore, ktory przez
Kotlin SQLCipher otwiera noBackupFilesDir/torchat-local.db. W tym samym czasie
AndroidEngineHost przekazuje te sama sciezke do Rust engine. To oznacza dwoch
wlascicieli i dwa rozne SQL backends dla tego samego pliku.

## 1.2 Zmiany zaleznosci

1. Otworzyc common/torchat-client-engine/Cargo.toml.
2. Zastapic rusqlite z feature bundled wariantem SQLCipher dzialajacym na
   Androidzie, Windows, Linux i macOS.
3. Przypiac wersje rusqlite, SQLCipher i wymaganych bibliotek TLS/crypto.
4. Jezeli wersje maja byc wspolne, przeniesc ich deklaracje do workspace
   Cargo.toml. Nie pozostawiac roznych przypadkowych wersji na platformach.
5. Nie zostawiac Androidowego Java SQLCipher jako fallbacku.
6. Potwierdzic cargo build engine dla host target i co najmniej Android arm64.

## 1.3 Zmiany ClientDatabase::open

Plik: common/torchat-client-engine/src/storage/sqlite.rs.
Symbol: ClientDatabase::open(path, database_key).

1. Otworzyc polaczenie SQLCipher.
2. Bezposrednio po open ustawic PRAGMA key z database_key.
3. Nie logowac klucza i nie zachowywac jego kopii w logach, errorach ani DTO.
4. Usunac linie let _ = database_key.expose().
5. Przed pierwszym selectem, integrity check i migracja ustawic:
   PRAGMA key, PRAGMA foreign_keys = ON, WAL i busy_timeout.
6. Wykonac PRAGMA integrity_check po ustawieniu klucza.
7. Jesli wynik nie jest ok, zwrocic EngineError i nie tworzyc nowej bazy.
8. Uruchomic MigrationRunner dopiero po udanym integrity check.
9. Kazda nowa connection/transaction ma odziedziczyc wymagane ustawienia.
10. Potwierdzic, ze queries mapuja row.get po nazwach kolumn, nie po indeksach.

## 1.4 Nazwa nowej bazy i reset

1. W TorChatForegroundService.kt zmienic engine path z torchat-local.db na
   torchat-client-v1.db.
2. W desktop/src/runtime_engine_stdio.rs znalezc konfiguracje EngineConfig i
   ustawic analogiczna nazwe w desktop data directory.
3. W scripts/torchat.ps1 znalezc Clear-TorChatDesktopState oraz Android reset
   paths i dodac tylko jawne usuwanie torchat-client-v1.db, -wal i -shm.
4. Przed delete zweryfikowac absolutna sciezke i ograniczyc operacje do
   katalogu danych TorChat.
5. Nie otwierac ani nie migrowac automatycznie torchat-local.db lub starego
   LocalStore. Clean reset jest wymagany przez REFACTO1.MD.
6. Zaktualizowac teksty UI/logow resetu, aby jasno mowily o utracie lokalnych
   danych developerskich.

## 1.5 Testy SQLCipher

1. Dodac test otwarcia tymczasowej bazy poprawnym kluczem.
2. Dodac test, ze ten sam plik nie otwiera sie blednym kluczem.
3. Dodac test integrity_check po reopen.
4. Dodac test schema_migrations po czystym open.
5. Dodac test PRAGMA table_info wszystkich canonical tables.
6. Dodac Android FFI smoke test: engine otwiera zaszyfrowana baze bez Kotlin
   SQLCipher.
7. Dodac desktop smoke test ClientDatabase::open.

Kryterium: tylko ClientDatabase engine otwiera i migruje zaszyfrowana baze.

---

# 2. Publiczne read models z engine

## 2.1 Problem

MainActivity nadal odczytuje dane UI z TorChatForegroundService.activeStore.
Po usunieciu EncryptedMessageStore host musi pytac engine, nie SQLite.

Pliki do zmiany:
- common/client-engine-contract.md
- common/torchat-client-engine/src/command.rs
- common/torchat-client-engine/src/event.rs
- common/torchat-client-engine/src/actor.rs
- common/torchat-client-engine/src/storage/sqlite.rs
- mobile/android/app/src/main/kotlin/org/torchat/core/NativeClientEngine.kt
- desktop/src/runtime_engine_stdio.rs

## 2.2 Rozszerzenie kontraktu

1. W common/client-engine-contract.md opisac query commands:
   ListContacts, ListConversations, ListMessages { conversation_id },
   GetIdentity i GetProfile.
2. Uzyc jednego modelu: EngineCommand query i EngineEvent::Response z request id.
3. Nie wystawiac database handle, RuntimeSession, MLS snapshot, relay payload,
   kluczy ani retry internals.
4. Opisac kolejnosc list:
   conversations po last_message_at malejaco, messages po created_at rosnaco.
5. Opisac pusta liste jako sukces, nie null i nie blad.
6. Opisac stable DTO kontaktu, rozmowy i wiadomosci.

## 2.3 Command i actor

1. W command.rs dodac warianty EngineCommand dla query.
2. Dodac typy response lub przeniesc je do osobnego publicznego DTO module.
3. W ClientEngineActor::handle_command w actor.rs dodac branch dla kazdego query.
4. W ClientDatabase dodac list_contacts, list_conversations, list_messages,
   get_identity i get_profile albo odpowiedniki.
5. W SqliteRuntimeStorage nie dodawac API dla hosta; host ma rozmawiac z actor.
6. Mapowac SQL po nazwie kolumny.
7. Zwrocic EngineEvent::Response z tym samym request id.
8. Zachowac actor jako jedynego wlasciciela connection i runtime state.

## 2.4 FFI i hosty

1. W common/torchat-client-engine-ffi/src/c_api.rs upewnic sie, ze nowe JSON
   commands przechodza przez submit_json bez osobnego ABI.
2. W NativeClientEngine.kt dodac helper submitQueryAndAwait, jesli obecny
   submitCommandAndAwait nie zwraca typed response.
3. W desktop runtime_engine_stdio.rs zmapowac JSONL query do identycznych
   EngineCommand values.
4. Nie dodawac osobnego Android query protocol ani osobnego desktop query
   protocol.

## 2.5 Testy

1. Zapisac contact, conversation i message przez publiczne engine commands.
2. Odczytac je przez ListContacts, ListConversations i ListMessages.
3. Porownac ID, state, unread_count, preview i timestamps.
4. Sprawdzic, ze OpenConversation resetuje unread i query widzi wynik po commit.
5. Sprawdzic puste listy po czystym bootstrap.

Kryterium: host dostaje wszystkie read models wylacznie przez engine.

---

# 3. Android bez Kotlin storage i legacy runtime

## 3.1 MainActivity

Plik: mobile/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt.

1. Znalezc branch RuntimeContract.CONTACTS.
2. Zastapic activeStore?.contacts() wywolaniem ListContacts przez engine.
3. Znalezc branch RuntimeContract.CONVERSATIONS.
4. Zastapic activeStore?.conversations() wywolaniem ListConversations.
5. Znalezc branch RuntimeContract.MESSAGES.
6. Zastapic activeStore?.conversation(id) wywolaniem ListMessages.
7. Wydzielic cienki helper mapujacy EngineResponse do MethodChannel Result.
8. Nie mapowac Kotlinowo states, unread, preview ani pairing status.
9. Usunac import net.sqlcipher.database.SQLiteDatabase.
10. Usunac SQLiteDatabase.loadLibs(this) z onCreate.

## 3.2 TorChatForegroundService

Plik: mobile/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt.

1. Usunac import org.torchat.data.EncryptedMessageStore.
2. Usunac val store = EncryptedMessageStore(applicationContext, databasePassphrase).
3. Zachowac databasePassphrase tylko jako engine databaseKey pobrany z
   LocalSecretStore.
4. Usunac activeStore = store.
5. Usunac companion property activeStore.
6. Usunac wszystkie reset/close activeStore w onDestroy i error path.
7. Usunac store.mlsInbox() i NativeIdentity.restoreMls(saved).
8. Engine ma sam odtwarzac MlsMember i DirectConversation z conversation_mls.
9. Zachowac Tor startup, LocalSecretStore, AndroidEngineHost, event pump,
   PlatformFact i Android notifications.
10. Nie dodawac reconnect actor, retry tick, pairing sync tick lub receipt tick
    w Kotlinie.

## 3.3 Usuniecie Kotlin store

1. Usunac mobile/android/app/src/main/kotlin/org/torchat/data/EncryptedMessageStore.kt.
2. Przeszukac callerow MessageStore, SqlCatalog, ChatModels i storage DTO.
3. Usunac MessageStore, SqlCatalog i tylko te modele/tests, ktore sa wylacznie
   implementacja starego store.
4. Nie usuwac generated DTO, jezeli sa juz potrzebne przez nowy bridge.
5. Usunac mobile/android/app/src/main/assets/sql/ razem z migrations i queries.
6. Przed delete wykonac rg dla assets/sql, SqlCatalog i nazw query.
7. Usunac SQLCipher i androidx.sqlite z mobile/android/app/build.gradle.kts.

## 3.4 Usuniecie starego runtime ABI

1. Wykonac rg NativeClientRuntime i torchat_client_runtime w mobile/android.
2. Jesli brak production callerow, usunac
   mobile/android/app/src/main/kotlin/org/torchat/core/NativeClientRuntime.kt.
3. Usunac mobile/android/app/src/main/jniLibs/arm64-v8a/libtorchat_client_runtime.so.
4. Sprawdzic NativeClientEngine.kt: Native.load ma wskazywac torchat_client_engine.
5. Sprawdzic scripts/internal/build-android-core.ps1: cargo ndk buduje tylko
   torchat-client-engine-ffi i kopiuje tylko libtorchat_client_engine.so.
6. Sprawdzic deploy-android.ps1 i build-clients.ps1 pod katem starych nazw.

## 3.5 Usuniecie Android relay

1. Wykonac rg AndroidRelayTransport, TorSocksSocketFactory i OkHttpClient.
2. Usunac mobile/android/app/src/main/kotlin/org/torchat/transport/AndroidRelayTransport.kt.
3. Usunac TorSocksSocketFactory.kt i klasy uzywane tylko przez ten relay.
4. Usunac com.squareup.okhttp3:okhttp z app/build.gradle.kts po potwierdzeniu
   braku innych callerow.
5. Platforma przekazuje tylko TorStatus, TorEndpointAvailable,
   TorEndpointLost, AppVisibilityChanged i NetworkChanged.
6. Relay reader/writer, heartbeat, reconnect i retry maja pozostac w
   common/torchat-client-engine/src/relay oraz ClientEngineActor.

Kryterium: Android nie zawiera SQLCipher Java API, Android SQLite,
EncryptedMessageStore, NativeClientRuntime, AndroidRelayTransport ani assets SQL.

---

# 4. Generowany kontrakt Rust, Kotlin i Dart

## 4.1 Zrodlo prawdy

1. Wybrac schemars na publicznych typach Rust albo JSON Schema w
   common/client-runtime-schema.
2. Zalecany wariant: schema generowana z EngineConfig, EngineCommand,
   EngineResponse, EngineEvent, PlatformFact i publicznych runtime DTO.
3. Nie generowac typow actor, storage transaction, MLS internals i secrets.
4. Ustalic camelCase, pole type, requestId, nullability i timestamp encoding.

## 4.2 Generator

1. Utworzyc tools/torchat-contract-gen.
2. Generator tworzy:
   mobile/android/app/src/main/kotlin/org/torchat/generated/EngineContract.kt.
3. Generator tworzy:
   mobile/lib/core/runtime/generated/runtime_contract.g.dart.
4. Generator tworzy:
   mobile/lib/core/models/generated/runtime_models.g.dart.
5. Kazdy plik ma naglowek generated - do not edit.
6. Dodac wewnetrzny build task lub script regeneracji; nie dodawac publicznej
   komendy do scripts/torchat.ps1.
7. Dodac check wykrywajacy nieaktualne generated files.

## 4.3 Usuniecie recznych kopii

1. Zastapic mobile/android/app/src/main/kotlin/org/torchat/mobile/RuntimeContract.kt
   generated EngineContract.kt albo usunac go.
2. Usunac RuntimeSendEffect.kt, jesli reprezentuje stary adapter-only protocol.
3. Zastapic mobile/lib/core/runtime/runtime_contract.dart generated contract.
4. Zastapic reczne parsing files runtime_payload.dart i runtime_response.dart
   generated DTO tam, gdzie dubluja wire schema.
5. Zaktualizowac common/client-engine-contract.md o wersje schema i generator.
6. Zachowac tylko cienkie MethodChannel/EventChannel conversion do primitive maps.

## 4.4 Testy kontraktu

1. Rust generuje fixtures po jednym dla kazdego command/event/response.
2. Kotlin test dekoduje te fixtures wygenerowanym kodem.
3. Dart test dekoduje te same fixtures.
4. Unknown type lub enum ma dawac kontrolowany blad, nie ciche pominiecie.

Kryterium: Rust jest jedynym zrodlem nazw, enumow i DTO.

---

# 5. Flutter bez adapter-only commands

## 5.1 Interfejs

Plik: mobile/lib/client_runtime.dart.

1. Usunac prepareAcceptPairing.
2. Usunac commitAcceptPairing.
3. Usunac prepareRejectPairing.
4. Usunac commitRejectPairing.
5. Usunac prepareCancelPairing.
6. Usunac confirmPairingCancelled.
7. Usunac preparePendingSendEffects i preparePendingReceiptEffects.
8. Usunac wszelkie publiczne expedite retry, transport outcome i welcome helper.
9. Pozostawic publiczne commands: pairing intents, nickname, verify contact,
   open/close/start conversation, send message i publiczne queries.

## 5.2 Bridge i repository

Pliki:
- mobile/lib/core/runtime/runtime_bridge_base.dart
- mobile/lib/core/runtime/runtime_repository.dart
- mobile/lib/core/runtime/runtime_contract.dart
- mobile/lib/core/runtime/runtime_payload.dart
- mobile/lib/core/runtime/runtime_response.dart

1. Usunac implementacje i call sites wszystkich usunietych methods.
2. Zastapic wieloetapowy accept jednym acceptPairing(pairingId).
3. Zastapic effects canonical EngineEvent.
4. Nie tworzyc message ID, receipt, retry attempt ani MLS payload w Dart.
5. Usunac PairingPreparation, PairingCancelEffect i RuntimeSendEffect, jezeli po
   migracji nie sa częscia publicznego generated contract.
6. Zaktualizowac AppController i screens do nowych response/event DTO.

## 5.3 AppController

Plik: mobile/lib/app/app_controller.dart.

1. Usunac wyliczanie canonical InviteState, ConversationState i MessageState.
2. AppController moze przechowywac loading, ekran, filter i prezentacje bledu.
3. AppController nie moze zmieniac unread count, pairing terminal state,
   delivery state ani contact existence.
4. Dodac test, ze event engine jest mapowany na stan widoku bez ponownego
   wyliczania logiki domenowej.

Kryterium: Flutter jest UI i bridge, nie czescia runtime lifecycle.

---

# 6. Desktop bez legacy runtime

## 6.1 Pliki, ktore maja pozostac

- desktop/src/main.rs
- desktop/src/cli.rs
- desktop/src/runtime_engine_stdio.rs
- desktop/src/tor_runtime.rs
- desktop/src/identity_store.rs

main.rs ma uruchamiac runtime_engine_stdio::run_stdio_engine jako jedyna
sciezke produkcyjna.

## 6.2 Pliki do usuniecia lub przeniesienia do test fixtures

Przed usunieciem kazdego pliku uruchomic codegraph callers dla kluczowego
symbolu i rg dla nazwy modulu.

1. Usunac desktop/src/runtime_state.rs i DesktopState.
2. Usunac desktop/src/runtime_flow.rs.
3. Usunac desktop/src/runtime_storage.rs i DesktopRuntimeStorage.
4. Usunac desktop/src/runtime_adapter.rs.
5. Usunac desktop/src/runtime_support.rs.
6. Usunac desktop/src/runtime_wire.rs.
7. Usunac desktop/src/runtime_stdio.rs.
8. Usunac desktop/src/store.rs i LocalStore.
9. Usunac desktop/src/transport.rs.
10. Usunac desktop/src/model.rs.
11. Usunac desktop/src/sql.rs.
12. Przepisac lub usunac desktop/src/runtime_conformance.rs, jezeli testuje
    LocalStore zamiast canonical ClientDatabase.
13. Fixture MLS i relay przeniesc do testow common/torchat-client-engine.

## 6.3 Zaleznosci

1. Po usunieciu modulow otworzyc desktop/Cargo.toml.
2. Usunac desktopowe rusqlite, jesli nie ma callerow.
3. Usunac desktopowe reqwest, tokio-socks i tokio-tungstenite, jesli relay jest
   tylko w engine.
4. Zachowac tylko CLI, Tor process host, JSONL, secrets i engine dependency.
5. Potwierdzic brak feature legacy-desktop-runtime.

Kryterium: desktop nie posiada drugiego storage, relaya, MLS ani runtime flow.

---

# 7. FFI, build i artefakty

## 7.1 C ABI

Pliki:
- common/torchat-client-engine-ffi/src/c_api.rs
- common/torchat-client-engine-ffi/src/handle.rs
- common/torchat-client-engine-ffi/src/lib.rs

1. Sprawdzic, ze kazdy extern C przechodzi przez catch_unwind.
2. Sprawdzic kopiowanie wejsciowego JSON przed powrotem z ABI.
3. Sprawdzic idempotentny shutdown.
4. Sprawdzic, ze free wykonuje shutdown i zwalnia tylko jeden handle allocation.
5. Sprawdzic, ze free_string zwalnia tylko string engine.
6. Dodac test double shutdown, submit po shutdown, poll po shutdown i free po
   shutdown.
7. Nie dodawac importStateJson, exportStateJson ani runtime snapshots.

## 7.2 Android build

1. scripts/internal/build-android-core.ps1 buduje tylko
   torchat-client-engine-ffi przez cargo ndk.
2. Script pakuje tylko libtorchat_client_engine.so.
3. Usunac kopiowanie libtorchat_client_runtime.so i libtorchat_core.so.
4. Zweryfikowac scripts/internal/build-clients.ps1.
5. Zweryfikowac scripts/deploy-android.ps1.
6. Nie commitowac build output, target, database, WAL/SHM lub logow.

## 7.3 Desktop build

1. desktop/Cargo.toml ma path dependency do torchat-client-engine.
2. scripts/internal/build-desktop-runtime.ps1 buduje engine-first desktop.
3. Brak stalej, feature lub argumentu uruchamiajacego legacy stdio runtime.

Kryterium: Android laduje jedna biblioteke engine, desktop linkuje ten sam crate.

---

# 8. Testy semantyczne

## 8.1 Transakcje

Pliki: common/torchat-client-runtime/src/runtime.rs,
common/torchat-client-runtime/src/session.rs,
common/torchat-client-engine/src/actor.rs i storage tests.

1. Zasymulowac blad zapisu przed commit.
2. Sprawdzic rollback SQL.
3. Sprawdzic restore RuntimeSession.
4. Sprawdzic brak publikacji staged RuntimeEvent.
5. Sprawdzic restore MLS in memory.

## 8.2 Send

1. Utworzyc conversation przez publiczny command.
2. Wyslac SendMessage.
3. Sprawdzic jeden message ID.
4. Sprawdzic atomowy zapis message, relay payload, MLS snapshot i summary.
5. Sprawdzic niezmiennosc relay payload na retry.
6. Zasymulowac Forwarded, receipt i disconnect.
7. Sprawdzic QUEUED, SENDING, SENT i DELIVERED.
8. Sprawdzic reset stalego SENDING do QUEUED.

## 8.3 Receive i dedupe

1. Pierwszy envelope decryptuje i zapisuje message.
2. Ten sam sender/message ID/hash nie decryptuje ponownie.
3. Duplikat nie zwieksza unread i nie emituje drugiego message_received.
4. Rozny hash dla tego samego sender/message ID jest protocol violation.
5. Sprawdzic payload.messageId rowne envelope.messageId.
6. NotificationRequested ma pojawic sie tylko po commit.

## 8.4 Pairing

1. SubmitPairingCode zapisuje durable pairing outbox.
2. Inbox dedupe i expiry dzialaja w engine.
3. AcceptPairing tworzy MLS, contact, conversation i pending welcome w jednej
   transakcji.
4. RejectPairing, CancelPairing i ArchivePairing sa tylko publicznymi commands.
5. Welcome receive nie uzywa Kotlin/Desktop helperow.

## 8.5 Relay i retry

1. TorEndpointAvailable rozpoczyna relay connect.
2. TorEndpointLost zamyka relay i emituje connection event.
3. Test handshake, auth, ready, ping/pong i stale generation.
4. Test control channel 64, data channel 256 i engine facts 256.
5. Test priority Pong, Close, Shutdown, Ready i AuthError.
6. Test sleep_until dla message, receipt, pairing, welcome, ack i reconnect.

## 8.6 FFI lifecycle

1. Test create, start, submit, poll, shutdown, free.
2. Test double shutdown.
3. Test submit i platform fact po shutdown.
4. Test panic nie przekracza granicy C ABI.
5. Test brak event po free.

Kryterium: krytyczne reguly sa testowane w engine, nie w hostach.

---

# 9. Finalny audit

## 9.1 Obowiazkowe wyszukiwania

Kazde production trafienie jest bledem:

1. rg EncryptedMessageStore.
2. rg RuntimeStateSnapshot.
3. rg AndroidRelayTransport.
4. rg NativeClientRuntime.
5. rg torchat_client_runtime mobile/android.
6. rg DesktopRuntimeStorage.
7. rg DesktopState desktop/src.
8. rg LocalStore desktop/src.
9. rg prepareAcceptPairing.
10. rg commitAcceptPairing.
11. rg prepareRejectPairing.
12. rg commitRejectPairing.
13. rg prepareCancelPairing.
14. rg confirmPairingCancelled.
15. rg preparePendingSendEffects.
16. rg preparePendingReceiptEffects.
17. rg importStateJson.
18. rg exportStateJson.
19. rg desktop/sql.
20. rg assets/sql.
21. rg OkHttpClient mobile/android/app/src/main.
22. rg SQLiteDatabase mobile/android/app/src/main.

Test fixture jest dopuszczalny tylko, gdy nie jest kompilowany jako produkcyjny
host i ma jasne uzasadnienie.

## 9.2 Schema parity

1. Otworzyc tymczasowa engine database na Androidzie i desktopie.
2. Porownac PRAGMA table_info dla contacts, conversations, messages,
   conversation_mls, pairing_inbox, pairing_outbox, pending_welcomes,
   used_invites, received_envelopes i delivery_receipts.
3. Porownac foreign keys i schema_migrations.
4. Rowniez sprawdzic identyczne kolumny, typy, nullability i primary keys.

## 9.3 Serwer live-only

1. Przeszukac server/torchat-server/src i server/torchat-server/sql.
2. Potwierdzic brak tabel i kodu dla body, ciphertext, envelope, history,
   message cache i MLS snapshots.
3. Dopuszczalne sa installations, sessions, pairing metadata i contacts.

## 9.4 Koncowe checki

1. cargo check -p torchat-client-runtime -p torchat-client-engine
   -p torchat-client-engine-ffi -p torchat-desktop.
2. Targetowane cargo test dla transaction, storage, relay, pairing i FFI.
3. mobile/android/gradlew.bat :app:compileDebugKotlin.
4. Z katalogu mobile: flutter analyze lib/core/runtime lib/mobile_bridge.dart
   lib/windows_runtime.dart lib/client_runtime.dart.
5. Smoke flow na Androidzie i desktopie: bootstrap, Tor endpoint, connect,
   pairing, send, receive, restart engine i odczyt historii.
6. Potwierdzic, ze reset client state jest jawny i nie usuwa Docker/Tor stack
   poza zakresem wybranej komendy.

## Definicja zakonczenia

Refaktor jest zakonczony tylko gdy:

- Android i desktop uzywaja tego samego torchat-client-engine.
- Istnieje jedna SQLCipher implementacja i jeden katalog migrations.
- Engine jest jedynym wlascicielem SQLite, MLS, relay, reconnect i retry.
- Kotlin, desktop i Flutter nie maja adapter-only lifecycle commands.
- Flutter uzywa generowanego, typowanego kontraktu.
- Nie ma aktywnych legacy paths ani starych katalogow SQL.
- Serwer pozostaje live-only i nie przechowuje wiadomosci.

