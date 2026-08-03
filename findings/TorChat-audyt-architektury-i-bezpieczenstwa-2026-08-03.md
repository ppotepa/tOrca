# Kompleksowy audyt aplikacji TorChat

**Status:** `PARTIAL REVIEW`  
**Data audytu:** 3 sierpnia 2026  
**Zakres materiału:** agregat CODECAT repozytorium `D:\Git\torchat` — 423 pliki, 76 224 linie, 2 780 151 bajtów.  
**Charakter audytu:** statyczny audyt architektury, protokołu, niezawodności, storage, kryptografii aplikacyjnej, Flutter/Android/desktop, relay i CI/CD.

> `PARTIAL REVIEW` nie oznacza, że przejrzano tylko fragment dostarczonego agregatu. Wszystkie 423 zawarte pliki zostały zinwentaryzowane i objęte przeglądem statycznym, a krytyczne ścieżki prześledzono ręcznie. Status wynika z dwóch ograniczeń: eksporter pominął 81 elementów przed utworzeniem agregatu, bez podania ich ścieżek, oraz w środowisku audytu nie były dostępne toolchainy `cargo`, `flutter`, `dart` i `pwsh`, więc nie wykonano buildów, testów, clippy, auditów zależności ani real-Tor E2E.

## 0. Metodyka i ograniczenia

- Za źródło zachowania uznano kod wykonawczy; komentarze i testy traktowano jako dowód intencji, nie poprawności end-to-end.
- Każdy finding rozróżnia błąd potwierdzony od ryzyka architektonicznego i ma ścieżki oraz zakresy symboli/linii.
- Pliki lock przeanalizowano pod kątem duplikacji stosów kryptograficznych i supply chain; pliki generowane sprawdzono pod kątem źródła generacji i driftu, bez ręcznego audytu każdej linii boilerplate.
- Nie wykonano: `cargo fmt/check/test/clippy`, `cargo audit`, `flutter analyze/test/build`, Gradle tests, PowerShell test suite, Docker compose smoke test ani skryptu dwóch silników przez Tor. Wyników tych poleceń raport nie deklaruje.
- Agregat zawiera mojibake. Bez dostępu do oryginalnych bajtów Git nie rozstrzygnięto, czy problem jest w repo, czy w eksporcie.

---

# 1. Executive summary

TorChat nie jest już prostym proof of concept. Baza ma kilka rozwiązań, które zwykle pojawiają się dopiero po pierwszych awariach produkcyjnych: trwały sender outbox, receiver inbox/dedupe, rozdzielenie `FORWARDED` od `DELIVERED`, persistowanie post-encryption/post-decryption MLS snapshots, monotoniczne endpoint sequence, capability proof w handshake, bounded główne kanały, SQLCipher, migracje transakcyjne, restart recovery i test dwóch realnych silników przez Tor. Kierunek ewolucji jest zasadniczo poprawny.

Jednocześnie wydanie 0.1 nie powinno zostać uznane za bezpieczne produkcyjnie przed usunięciem pięciu problemów P0. Najgroźniejszy jest workflow usuwania relacji: zwykła treść wiadomości z magicznym prefiksem jest interpretowana jako autorytatywne polecenie i może pozwolić zdalnemu kontaktowi wybrać kasowanie historii odbiorcy. Drugi błąd znajduje się dokładnie na granicy commitu odbioru: awaria wysłania delivery receipt po udanym zapisie wiadomości powoduje P2P `Rejected` i kryptograficzne zablokowanie peera. Desktop przechowuje długoterminowy klucz tożsamości w plaintext i wyprowadza z niego klucz SQLCipher. Ścieżka host/staging nie przekazuje wymaganego pairing secret, a idempotency `command_id` ginie lub nie jest stabilna między hostami.

Rekomendacja: **kontynuować projekt i refaktoryzować ewolucyjnie, ale zatrzymać release 0.1 do zamknięcia P0 i testów regresyjnych**. Pełny rewrite nie jest uzasadniony. Należy zachować core protocol, runtime rules, SQLCipher storage, peer transport, generated contract i ownership Android ForegroundService. Największą zmianą architektoniczną powinno być wprowadzenie jawnych, trwałych process managerów dla pairingu, message delivery, capability exchange i relationship removal oraz oddzielenie „local app usable” od gotowości relay/P2P.

Rozkład findingów: **8 HIGH**, **12 MEDIUM**, **1 LOW**, **1 INFO**. Nie stwierdzono w dostarczonym materiale potwierdzonego błędu klasy BLOCKER/CRITICAL w samych prymitywach kryptograficznych; istnieją jednak HIGH dotyczące utraty danych, przejęcia lokalnych sekretów i trwałej desynchronizacji workflow.

## 1.1 Ocena dojrzałości

| Obszar | Ocena 1–5 | Uzasadnienie |
|---|---:|---|
| Architektura | 3 | Czytelne crate boundaries i actor, lecz workflow nadal przeciekają między UI, SQL, runtime i transportem. |
| Poprawność domenowa | 3 | Jawne message/pairing rules i idempotency, ale relationship removal oraz read receipts są niespójne. |
| Bezpieczeństwo | 2 | Dobry handshake i E2E; desktop secret storage i semantyka zdalnego removal blokują wydanie. |
| Prywatność | 2 | Relay nie przechowuje ciphertextów, lecz loguje surowy graf społeczny. |
| Niezawodność | 3 | Durable queues, dedupe i restart recovery; brak jitter/dead-letter i błąd post-commit receipt. |
| Storage | 3 | SQLCipher, WAL, FK, migracje i indeksy; za dużo logiki w triggerach, brak anti-rollback/retencji command store. |
| P2P przez Tor | 3 | Silny handshake, limity, ACK i sesje; wymaga szerszych testów race/crash/fuzz. |
| Pairing | 3 | Jednorazowe invite, Welcome retention i recovery; process manager rozproszony po wielu warstwach. |
| Mobile/platform | 2 | Android service/Keystore są dobre; UI hard-gate i lifecycle/operation ID wymagają utwardzenia. |
| Serwer/relay | 2 | Bounded live routing i auth, lecz single-instance state, metadata logs i abuse limits są niedojrzałe. |
| Testy | 2 | Wartościowe testy resilience i real Tor, ale brak pełnej crash/property/fuzz matrix. |
| Operacyjność | 2 | CI jakości istnieje, ale staging secret jest niespójny, supply chain i provenance niepełne. |
| Gotowość produkcyjna | 2 | Działający PoC z solidnymi fundamentami, lecz P0 uniemożliwia bezpieczny release. |

**Werdykt:** działający PoC z elementami solidnej bazy produktu; po P0/P1 może dojść do poziomu 3 bez przepisywania systemu.

---

# 2. Inwentarz repozytorium

| Obszar | Liczba plików | Linie | Bajty | Zakres przeglądu |
|---|---:|---:|---:|---|
| Dokumentacja i konfiguracja repozytorium | 10 | 264 | 6 840 | wszystkie pliki w agregacie |
| Kod mobilny i integracje platformowe | 53 | 5 306 | 201 290 | wszystkie pliki w agregacie |
| Kod produkcyjny | 194 | 47 795 | 1 724 350 | wszystkie pliki w agregacie |
| Kod wygenerowany  lock i zasoby zależności | 16 | 5 952 | 173 169 | wszystkie pliki w agregacie |
| Kontrakty i modele protokołu | 3 | 438 | 30 711 | wszystkie pliki w agregacie |
| Migracje i zapytania SQL | 54 | 1 016 | 34 325 | wszystkie pliki w agregacie |
| Serwer / relay | 2 | 1 845 | 64 303 | wszystkie pliki w agregacie |
| Skrypty  CI/CD i infrastruktura | 40 | 7 257 | 315 707 | wszystkie pliki w agregacie |
| Testy | 51 | 6 773 | 224 834 | wszystkie pliki w agregacie |
| **Razem** | **423** | **76 224** | **2 780 151** | **zinwentaryzowane** |

Pełna lista plików wraz z kategorią, liczbą linii i głębokością przeglądu znajduje się w osobnym artefakcie `TorChat-audyt-file-inventory.csv`.

## 2.1 Elementy pominięte przed agregacją

| Powód eksportera | Liczba | Możliwość wskazania ścieżek |
|---|---:|---|
| gitignore | 14 | nie — agregat podaje tylko licznik |
| hidden_directory | 9 | nie — agregat podaje tylko licznik |
| ignored_directory | 1 | nie — agregat podaje tylko licznik |
| ignored_extension | 19 | nie — agregat podaje tylko licznik |
| no_plugin_match | 37 | nie — agregat podaje tylko licznik |
| output_file | 1 | nie — agregat podaje tylko licznik |
| **Razem** | **81** | brak ścieżek w dostarczonym materiale |

Nie należy utożsamiać tych 81 elementów z kodem produkcyjnym. Mogą obejmować artefakty, pliki usługi systemd, zasoby binarne, lokalne wyniki i pliki nieobsługiwanych typów. Ponieważ ścieżki są nieznane, raport nie może potwierdzić ich nieistotności.

## 2.2 Generowanie kontraktów

- Kanoniczny manifest engine znajduje się w `common/client-engine-contract.json`.
- Generator `tools/torchat-contract-gen/src/main.rs` wytwarza kontrakty hostów, m.in. Dart/Kotlin.
- CI uruchamia `check-runtime-contract.ps1`, a testy Flutter/Kotlin porównują manifest. To ogranicza drift.
- Nadal istnieje ręczne mapowanie komend i payloadów w `windows_runtime.dart`, bridge’ach i event mapperach. Generator powinien docelowo wytwarzać także typed request/response adapters, nie tylko stałe.

---

# 3. Mapa architektury

```text
Flutter UI / controllers / feature views
  -> RuntimeRepository + ApplicationSnapshot projection
    -> RuntimeBridge
      -> Android: ForegroundService -> AndroidEngineHost -> NativeClientEngine (C ABI)
      -> Windows/Linux/macOS: desktop stdio sidecar -> ClientEngine Rust
        -> generated JSON engine contract + request/response/event stream
          -> ClientEngine
            -> ClientEngineActor (single serialized orchestration loop)
              -> torchat-client-runtime
                 - domain models, state-transition rules, RuntimeSession
                 - RuntimeStorage / RuntimeTransport ports
              -> ClientDatabase / SqliteRuntimeStorage
                 - SQLCipher, WAL, FK, migrations, inbox/outbox/projections
              -> DirectConversation / OpenMLS provider snapshots
              -> PeerTransport
                 - local TCP/WebSocket listener
                 - Tor SOCKS outbound dial
                 - endpoint signature + sequence
                 - capability HMAC + signed transcript
                 - bounded per-contact queues and ACKs
              -> Relay adapters
                 - long-lived WebSocket event/data path
                 - spawn_blocking HTTP control worker
              -> PlatformAction
                 - configure/rotate onion service

Relay server
  -> Axum HTTP bootstrap/profile/pairing/session API
  -> PostgreSQL control metadata
  -> in-memory challenge/rate/session/connection maps
  -> live-only WebSocket envelope forwarding
  -> Tor onion service via Docker/host deployment
```

## 3.1 Kierunek zależności

Prawidłowy kierunek jest w większości zachowany: core nie zależy od platform, runtime zależy od core, engine od runtime/core, hosty od engine contract. Najważniejsze naruszenia nie są cyklem crate’ów, lecz **przeciekiem odpowiedzialności**:

- UI tworzy domenową wiadomość usunięcia relacji i decyduje o kolejności side effects.
- SQL trigger interpretuje format protokołu aplikacyjnego i wykonuje workflow domenowy.
- Server `main.rs` zawiera router, auth, pairing, session registry, routing, cleanup i storage mapping.
- Hosty decydują o semantyce idempotency zamiast przekazywać stabilny operation ID z warstwy intencji.

## 3.2 Komponenty i granice

| Komponent | Odpowiedzialność | Stan własny | Efekty zewnętrzne / granica bezpieczeństwa |
|---|---|---|---|
| torchat-core | Tożsamość, podpisy, invite, payloady aplikacyjne/relay, peer handshake, OpenMLS wrapper | Klucze w obiektach Identity/MlsMember/DirectConversation | Serializacja podpisywana, MLS, HMAC capability; nie powinien znać UI/storage. |
| torchat-client-runtime | Reguły domenowe, modele, state transitions, RuntimeSession, porty storage/transport | Transakcyjny stan sesji i projekcje domenowe | Nie powinien wykonywać blocking network; zwraca typed effects. |
| torchat-client-engine | Orkiestracja, lifecycle, recovery, transport policy, projection/idempotency | Actor state, mapy MLS, connection state, transient sessions | Jedyna warstwa łącząca DB, Tor peer i relay; główna granica transakcyjna. |
| ClientDatabase/SQLCipher | Kanoniczne dane klienta, MLS snapshots, durable queues, dedupe | Plik SQLCipher | Commit jest granicą trwałości; wymaga anti-rollback i prostszej logiki domenowej. |
| PeerTransport | Uwierzytelnione P2P przez Tor, sesje, ACK, frame limits | Authorized peers, per-contact queues/sessions | Nie ufa peerowi przed proof/signatures; frame parsers są powierzchnią ataku. |
| Relay client | Control plane HTTP + live WebSocket forwarding | Token/session, writer, reconnect | Relay widzi logical IDs i timing, ale ciphertext pozostaje opaque. |
| FFI/stdio | Lifecycle engine, JSON, pamięć i panic boundary | Opaque handle, request map hosta | Musi zachować command ID, nie blokować UI thread i jednoznacznie własność pamięci. |
| Flutter | Projection/cache, UX, navigation, platform intents | Kopie snapshotu, transient focus/typing/presence | Nie powinien tworzyć wire payloadów ani wykonywać workflow relacji. |
| Android integration | Foreground service, Tor/onion, engine lifetime, notifications, secure store | Service-owned engine, Keystore-wrapped secrets | Granica procesu/lifecycle Android; dobry właściciel długowiecznego runtime. |
| Desktop sidecar | Tor process, identity/state path, stdio contract | Proces engine/Tor | Obecnie słaba granica secret storage i utrata command ID. |
| Relay server | Bootstrap, pairing directory/control, live routing | Postgres + procesowe maps | Złośliwy/kompromitowany relay nie może czytać treści, ale może korelować metadane. |

## 3.3 Własność stanu

| Stan | Kanoniczne źródło prawdy | Kopie/cache | Ryzyko wielowłasności |
|---|---|---|---|
| Profil/tożsamość | SQLCipher settings/runtime tables + OS secret dla klucza | RuntimeSession, Flutter snapshot | desktop key poza secure store; profile cache jest odtwarzalny. |
| Kontakty/ustawienia | SQLCipher `contacts` | RuntimeSession/Flutter | wymaga jednego transition path dla block/remove. |
| Pairing | pairing inbox/outbox + pending local MLS/welcome/ack/confirmation | relay DB i actor queues | workflow jest rozłożony między relay, runtime, actor i DB. |
| Konwersacje/wiadomości/unread | SQLCipher | Flutter repository/application state | projection stamp poprawia spójność; UI nie powinno pisać protokołu. |
| MLS | `conversation_mls` i pending invite MLS | actor `HashMap<String, DirectConversation>` | DB musi być kanoniczne po restarcie; brak anti-rollback całej bazy. |
| Peer endpointy | SQLCipher local/contact endpoint tables | PeerTransport authorization | sequence/signature ograniczają stale updates. |
| Capability | SQLCipher local/peer capability tables | PeerTransport authorized map | rotacja/revocation wymagają trwałego ACK i sesji invalidation. |
| Tor/relay readiness | ClientEngineActor + facts platformy | Flutter connection model | UI obecnie agreguje niezależne komponenty do jednego hard gate. |
| P2P sessions | PeerTransport + actor active session IDs | UI presence/connection projection | transient, po restarcie odbudowywane probe’ami. |
| Retry/backoff | durable queue rows + actor scheduler | transient timers `Instant` | brak jitter/dead-letter. |
| Typing/focus/presence | Peer control channel, transient UI state; `last_seen_at` trwałe | probe coordinator | best-effort; poprawnie poza MLS, ale nie mylić z delivery. |
| Read receipts | model/kontrakt przewiduje; realny outbound wyłączony | UI wywołuje i ignoruje błąd | niespójność produktu. |

---

# 4. Krytyczne przepływy end-to-end

## A. Uruchomienie aplikacji

1. Host ładuje/generuje identity i DB key. Android używa dwóch niezależnych sekretów opakowanych Keystore; desktop czyta plaintext identity i wyprowadza DB key — TC-003.
2. `ClientDatabase::open` ustawia SQLCipher key przed odczytem, włącza FK/WAL/busy timeout, sprawdza `integrity_check` i uruchamia migracje w transakcjach.
3. Actor ładuje profile/contacts, MLS snapshots, pending welcomes i quarantine senders.
4. `ClientEngineActor::run` binduje lokalny peer listener, odtwarza pending inbound envelopes, autoryzuje znane kontakty i emituje `ConfigureOnionService`.
5. Platforma uruchamia/konfiguruje usługę onion, następnie publikuje `TorEndpointAvailable` i `OnionServiceAvailable` z generation guard.
6. Publiczne `connect` nie wykonuje blocking onion HTTP na command path; actor planuje relay bootstrap w `spawn_blocking` i obsługuje reconnect.
7. Flutter pobiera jeden `ApplicationSnapshot` w transakcji z projection stamp, lecz pozostaje na boot aż do gotowości wszystkich transportów — TC-006.

**Crash invariants:** migracja i outbound encryption są transakcyjne; onion generation odrzuca stale facts; durable queues przeżywają restart. Transient platform actions/events mogą zostać utracone, ale są odtwarzane przez startup. Brakuje automatycznych crash tests na każdym punkcie.

## B. Pairing dwóch użytkowników

1. Kod parowania jest generowany/odświeżany przez relay control HTTP i ma TTL.
2. Wpisanie kodu tworzy idempotentny request sender→recipient w PostgreSQL; self-pair jest odrzucany.
3. Odbiorca pobiera inbox. Akceptacja tworzy podpisany `ContactInvite` z jednorazowym invite ID, MLS KeyPackage, opcjonalnym endpointem i zapisuje pending local invite MLS.
4. Pairing offer idzie przez relay. Druga strona waliduje podpis, installation ID/public key/fingerprint, recipient, TTL i self-invite.
5. Invite jest atomowo konsumowany; tworzona jest DirectConversation, MLS Welcome i pending durable welcome.
6. Welcome jest ponawiany do application-level `WelcomeApplied`, a samo relay `FORWARDED` nie kończy trwałego workflow.
7. Po commicie kontaktu wykonywane są contact confirmation, endpoint bootstrap i capability exchange jako efekty po transakcji.

**Ochrony obecne:** used invite, self-pair, podpis invite/endpoint, endpoint sequence, pending welcome, idempotentne merge/ACK, stale relationship boundary. **Braki:** process manager jest rozproszony; clock skew; brak kompletnej macierzy accept/reject/cancel races i repeated Welcome na dwóch realnych klientach.

## C. Wysłanie wiadomości

1. Runtime tworzy lokalną wiadomość `QUEUED/SENDING` w aktywnej transakcji.
2. Actor buduje typed `ApplicationPayloadV1::Message` i szyfruje dokładnie raz przez MLS.
3. W tej samej transakcji `persist_outbound_encryption` zapisuje wire ciphertext i post-encryption MLS snapshot, po czym claimuje próbę.
4. Po commicie tworzony jest `outbound_delivery`; transport policy wybiera P2P, relay fallback lub relay-only.
5. P2P `Persisted` przechodzi do `SENT`; P2P/application delivery receipt do `DELIVERED`; READ jest obecnie niespójne.
6. Retry korzysta z istniejącego `wire_ciphertext`; nie szyfruje ponownie i nie przesuwa MLS generation.
7. Relay `FORWARDED` oznacza wyłącznie zapis do socketu odbiorcy i mapuje się na `SENT`, nigdy `DELIVERED`.

**Gwarancja:** sender-side at-least-once, receiver effectively-once dla `(sender, messageId, ciphertextHash)`. Brak serwerowego store-and-forward. Nie znaleziono stanu, w którym normalny send commit przesuwa MLS bez zapisania ciphertextu; to jest pozytywny invariant.

## D. Odbiór wiadomości

1. Peer handshake uwierzytelnia kontakt przed przyjęciem frame.
2. P2P zapisuje envelope do durable inbox przed ACK `Persisted`.
3. Dedupe sprawdza sender+message ID i wymaga identycznego ciphertext hash; mutacja duplikatu jest odrzucana.
4. Actor odszyfrowuje MLS, waliduje payload message ID, zapisuje wiadomość, snapshot, dedupe i receipt w jednej transakcji.
5. Dopiero po commicie P2P powinien wysłać `Delivered`. Obecnie błąd flush receipt po commicie może zostać zmapowany na `Rejected` — TC-002.
6. Undecryptable pending peer envelope po restarcie jest quarantine’owany i peer trafia do crypto block; należy upewnić się, że tylko błędy kryptograficzne prowadzą do tej ścieżki.

## E. Handshake P2P

- Endpoint: Tor v3 address, fixed virtual port, protocol version, identity binding, podpis domenowy, positive sequence, successor monotonicity i optional expiry.
- ClientHello: installation ID, endpoint sequence, capability ID, HMAC proof i 32-bajtowy nonce.
- Transcript: osobna domena, oba hello/nonce, endpointy i session ID; client i server podpisują transcript.
- Capability proof używa HMAC verify, a secret jest dystrybuowany przez MLS-encrypted capability offer.
- Frame limits: 8 KiB pre-auth, 256 KiB authenticated frame, 128 KiB ciphertext budget; timeouts/keepalive i bounded in-flight.
- Endpoint updates są podpisane i odnoszą się do previous sequence.

Najważniejsze dalsze testy: replay tego samego hello/nonces/session, capability revoked w trakcie sesji, stale endpoint z przyszłym timestampem, downgrade version, concurrent inbound/outbound sessions i fuzz pre-auth frame.

## F. Relay i control plane

Control plane HTTP obsługuje bootstrap, profile, kody, pairing, contact confirmation i sessions. WebSocket jest live data/event plane dla opaque MLS ciphertext oraz control payloads. Serwer nie przechowuje application envelopes; recipient offline wraca do sendera. To ogranicza retencję treści, ale serwer widzi installation IDs, timing, message IDs i online status, a obecnie loguje je wprost — TC-011.

Jedna instancja działa z bounded outbound queue 256 i 30-sekundowym write completion timeout. Multi-instance nie działa poprawnie bez registry/pub-sub — TC-012. Uwierzytelnienie i body limits istnieją, lecz abuse limits są niewystarczające — TC-013.

## G. Usunięcie relacji

Obecna ścieżka jest głównym problemem P0. UI wysyła magiczną wiadomość, następnie niezależnie blokuje kontakt i wywołuje engine removal. SQL trigger rozpoznaje body i wykonuje remote transition. Istnieje typed payload w core, ale nie jest jedyną drogą. Tombstone/boundary chroni przed częścią stale replay, lecz remote timestamp i remote preserve-history są niewłaściwymi źródłami decyzji. Docelowo operacja musi być osobnym durable workflow z relationship epoch, local retention policy i ACK.

## H. Restart i odzyskiwanie kolejek

| Kolejka/efekt | Zapis przed efektem | Claim | Idempotency/dedupe | Zakończenie | Luka |
|---|---|---|---|---|---|
| Outgoing messages | tak: message+ciphertext+MLS | DB state/ack deadline | message ID + stored ciphertext | delivered/read/permanent failure | brak wspólnego dead-letter/jitter. |
| Inbound peer envelopes | tak przed Persisted ACK | PK sender+message | hash mismatch odrzucany | delivered/rejected | post-commit receipt błąd mapowany źle. |
| Delivery receipts | tak | claim deadline | message ID unique | P2P/relay outcome | efekt po commicie nie może cofać message ACK. |
| Pending Welcome | tak | attempt + next_attempt | invite ID | WelcomeApplied/expiry | pełna race matrix nieautomatyczna. |
| Pairing response/ACK/confirmation | tak | per-row claim | pairing ID | HTTP success/merge | workflow rozproszony. |
| Endpoint bootstrap/update | tak | sequence + claim | contact+sequence | ACK/verified successor | clock skew i poison item. |
| Capability offer | tak do app-level ACK | delivery ID | per-contact active delivery | CapabilityOfferAck | brak dead-letter; bootstrapping zależny od relay. |
| Typing/presence/focus | nie — best effort | bounded transient queue | coalescing/expiry | timeout | poprawnie poza MLS; nie gwarantuje delivery. |
| Relationship removal | niepoprawna hybryda message+local command | brak jednego claim | timestamp/prefix | tombstone | P0 TC-001. |

---

# 5. Model domenowy i state machines

## 5.1 Wiadomość

```text
QUEUED -> SENDING -> SENT -> DELIVERED -> READ
   ^         |         |
   |         +---------+-- transient failure -> QUEUED
   +------------------------ retry
QUEUED/SENDING/SENT -> FAILED (permanent/auth/rejected)
DELIVERED/READ nie są degradowane
```

Reguły w `message_rules.rs` są jawne i testowane. `FORWARDED|PEER_PERSISTED -> SENT`, `Delivered|PeerDelivered -> DELIVERED`. Największa niespójność to publiczne READ bez działającego outbound receipt.

## 5.2 Pairing

Stany: `PENDING, ACCEPTED, REJECTED, COMPLETED, EXPIRED, ARCHIVED, CANCELLED`. `pairing_rules.rs` ma jawne akcje i merge precedence. Jednak pełny pairing jest sagą obejmującą relay row, local inbox/outbox, local invite MLS, offer, Welcome, acknowledgement, contact confirmation, endpoint i capability. Te etapy nie są reprezentowane jako jeden durable process state, więc analiza pojedynczego enumu nie wystarcza.

## 5.3 Konwersacja, połączenie, endpoint i capability

- Konwersacja: `PENDING -> VERIFYING -> ACTIVE/OFFLINE/FAILED`; część przejść zależy od transportu i tombstone, nie wszystkie są wymuszone typami.
- Relay connection: `waiting_for_tor, disconnected, connecting, authenticating, waiting_for_ready, connected, backoff, stopped`; jawny enum i generation guard.
- Peer connection: `OFFLINE, CONNECTING, AUTHENTICATING, CONNECTED, BACKOFF`; sesje są transient, a reachability oparta na probes.
- Endpoint: brak rekordu / verified bundle; successor wymaga większej sequence i tej samej identity.
- Capability: active/revoked + sequence/expiry; storage jest typowany częściowo, lecz wiele state fields nadal jest tekstem w SQL.
- Relationship: nie ma jednego state machine; to konkretna klasa błędów uzasadniająca process manager, nie estetyczny pattern.

---

# 6. Pozytywne ustalenia warte zachowania

- Ciphertext i post-encryption MLS snapshot są persistowane razem; retry używa identycznego ciphertextu.
- Incoming peer envelope jest durable przed ACK `Persisted`; duplikat o innym hashie jest odrzucany.
- `FORWARDED` relay nie jest uznawany za `DELIVERED`; testy chronią przed downgrade po późnym outcome.
- Ephemeral MLS signals zostały świadomie wyłączone, aby nie zgubić ratchet generation; typing/presence/focus używają osobnego peer control.
- Peer endpoint jest podpisany, wiąże installation ID z public key/onion, ma monotonic sequence i domain separation.
- Capability proof jest HMAC-em z nonce i endpoint sequence; handshake podpisuje transcript po obu stronach.
- Frame limits i pre-auth limits są jawne; główne command/event/peer queues są bounded.
- SQLCipher key jest ustawiany przed odczytem; FK, WAL, busy timeout, integrity check i migration checks są obecne.
- Projection snapshot jest czytany w jednej transakcji z store ID/revision, co ogranicza mixed-revision UI.
- Android ForegroundService jest właścicielem długowiecznego engine, a sekrety są rozdzielone i opakowane Android Keystore.
- Relay ma bounded per-connection queue i nie przechowuje application ciphertext po rozłączeniu.
- CI ma clean-architecture, contract, SQL isolation, encoding i source-size checks oraz głównoliniowy real-Tor probe.
- Testy obejmują restart outbound delivery, inbound dedupe/hash mutation, pairing recovery, Welcome retention i stale relationship replay.

---

# 7. Threat model

| Zasób | Atakujący | Wektor | Obecna ochrona | Luka | Rekomendacja |
|---|---|---|---|---|---|
| Treść/MLS state | złośliwy relay/observer | podsłuch envelope | MLS/OpenMLS, Tor, relay opaque payload | metadata nadal widoczne/logowane | minimalizacja logów, padding/batching rozważyć później. |
| Tożsamość i DB desktop | lokalny malware/backup reader | odczyt installation.key | Unix 0600, SQLCipher | jeden plaintext sekret otwiera identity i DB | OS vault + niezależne DB key. |
| Historia relacji | złośliwy kontakt | magic body z preserveHistory=false | MLS uwierzytelnia nadawcę; tombstone guards | uwierzytelniony kontakt może sterować lokalną retencją | typed workflow, local policy. |
| Peer listener | nieautoryzowany peer | fałszywy hello/frame | endpoint signature, capability HMAC, transcript signatures, limits | wymaga fuzz/replay/concurrency tests | fuzz i bounded auth budgets. |
| Pairing | replayer/stary invite | ponowne offer/Welcome | invite ID, used_invites, TTL, pending welcome | clock skew/process rozproszony | relationship epoch, fake clock tests. |
| Endpoint/capability | kontakt/replayer | stary endpoint/secret | sequence, signature, revocation rows | wall clock, session invalidation races | epoch/sequence tests, durable revocation ACK. |
| Relay dostępność | bot przez Tor | challenge/ws flood | body limit, global challenge cap, sender pairing limit | brak bounded concurrency/per-anon budget | semafory, adaptive budgets. |
| Graf społeczny | operator/log backend | info logs | E2E chroni treść | raw sender+recipient+message ID | server log sanitizer/retention. |
| MLS continuity | lokalny restore/malware | rollback DB | SQLCipher/integrity | brak niezależnej anti-rollback kotwicy | secure checkpoint/version. |
| Actor/runtime | race/crash | kill między effect a commit | durable queues, transactions, claims | post-commit receipt mapping, brak full fault injection | commit-aware result + crash harness. |

---

# 8. Lista findingów

| ID | Severity | Priority | Kategoria | Tytuł | Effort | Confidence |
|---|---|---|---|---|---|---|
| TC-001 | HIGH | P0 | Poprawność domenowa / bezpieczeństwo danych | Usunięcie relacji jest interpretowane jak zwykła wiadomość, a zdalny kontakt może sterować retencją lokalnej historii | L | high |
| TC-002 | HIGH | P0 | Crash consistency / semantyka ACK | Błąd wysłania receipt po udanym commicie odbioru powoduje ACK `Rejected` i kryptograficzne zablokowanie peera | M | high |
| TC-003 | HIGH | P0 | Kryptografia / lokalne sekrety | Desktop przechowuje klucz tożsamości w jawnym pliku i wyprowadza z niego klucz SQLCipher | L | high |
| TC-004 | HIGH | P0 | Operacyjność / deployment | Konfiguracja host/staging nie dostarcza wymaganego `TORCHAT_PAIRING_SECRET` i serwer kończy proces podczas startu | S | high |
| TC-005 | HIGH | P0 | API / niezawodność po timeoutach | Idempotency `command_id` ginie na desktopie, a Android tworzy nowy identyfikator dla każdego wywołania | M | high |
| TC-007 | HIGH | P1 | Kryptografia / backup i recovery | Snapshoty MLS nie mają ochrony przed rollbackiem starszej kopii bazy | L | medium |
| TC-011 | HIGH | P1 | Prywatność / observability | Relay loguje surowe identyfikatory obu stron i message ID, tworząc trwały zapis grafu społecznego | S | high |
| TC-012 | HIGH | P1 | Serwer / skalowanie i dostępność | Relay nie jest bezpieczny dla wielu instancji: challenge, połączenia, rate state i routing są procesowe | L | high |
| TC-006 | MEDIUM | P1 | Mobile/UI / model gotowości | UI blokuje dostęp do lokalnych danych, dopóki Tor, listener, onion service i relay nie są jednocześnie gotowe | M | high |
| TC-008 | MEDIUM | P1 | Niespójność kontraktu produktu | Read receipts są częścią publicznego kontraktu i UI, ale engine zawsze odrzuca je jako `Unsupported` | M | high |
| TC-009 | MEDIUM | P1 | System rozproszony / retry | Retry jest deterministyczny, bez jittera i bez ogólnego dead-letter/permanent-failure lifecycle | M | high |
| TC-010 | MEDIUM | P1 | Współbieżność / backpressure | Kolejka relay-control jest nieograniczona i używa `Vec::remove(0)` | S | high |
| TC-013 | MEDIUM | P1 | Serwer / abuse i DoS | Niezalogowane endpointy bootstrap/session nie mają skutecznego per-origin ani globalnego concurrency budget | M | high |
| TC-017 | MEDIUM | P1 | Czas / system rozproszony | Ważność invite/endpoint i kolejność relationship removal zależą od nieskorygowanego wall clock | M | high |
| TC-018 | MEDIUM | P1 | CI/CD / supply chain | CI i supply chain nie są przypięte ani kompletne dla release security | M | high |
| TC-019 | MEDIUM | P1 | Testy | Brakuje automatycznych testów crash/fuzz/property dla kluczowych gwarancji, a real-Tor nie jest bramką PR | L | high |
| TC-014 | MEDIUM | P2 | Kryptografia / kompatybilność danych | Format snapshotu MLS zależy od prywatnego layoutu `openmls_memory_storage` i nie ma planu migracji wersji | L | high |
| TC-015 | MEDIUM | P2 | Storage / wzrost danych | `processed_commands` nie ma polityki retencji ani cleanupu | S | high |
| TC-016 | MEDIUM | P2 | Architektura / storage | Krytyczna logika relacji jest ukryta w 412-liniowej migracji triggerów i zdublowana w Rust | L | high |
| TC-022 | MEDIUM | P2 | Architektura / modularność | Największe moduły nadal łączą kilka odpowiedzialności i tworzą wysokie ryzyko zmian przekrojowych | L | high |
| TC-021 | LOW | P2 | Jakość / encoding | Mojibake jest widoczne w agregacie, ale nie można rozstrzygnąć, czy pochodzi z repozytorium czy eksportera | S | low |
| TC-020 | INFO | P2 | Semantyka dostarczenia | Relay fallback jest wyłącznie live forwarding, nie trwałym store-and-forward — kontrakt produktu musi to mówić wprost | S | high |

## TC-001 — Usunięcie relacji jest interpretowane jak zwykła wiadomość, a zdalny kontakt może sterować retencją lokalnej historii

**Severity:** HIGH  
**Priority:** P0  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Poprawność domenowa / bezpieczeństwo danych

**Dowód:**
- `mobile/lib/app/notification_safe_app_controller.dart:133-185` — UI tworzy tekst z prefiksem, wysyła go przez zwykłe `sendMessage`, a niezależnie od powodzenia wykonuje lokalne zablokowanie i `removeRelationship`.
- `mobile/lib/core/relationships/relationship_message.dart:3-37` — operacja jest kodowana jako `torchat-relationship-removed-v1:` + JSON z `removedAt` i `preserveHistory`.
- `common/torchat-client-engine/sql/migrations/014_runtime_integrity.sql:215-362` — trigger rozpoznaje prefiks w treści każdej przychodzącej wiadomości i może zablokować kontakt, anulować kolejki, skasować MLS/endpointy oraz — przy `preserveHistory=false` — historię wiadomości.
- `common/torchat-core/src/application.rs:82-93` oraz `common/torchat-client-engine/src/actor/application_envelope.rs:202-233` — istnieje typowany payload `RelationshipRemoved`, lecz ścieżka UI go nie używa.

**Opis:** Granica relacji jest obecnie zakodowana równolegle na trzech poziomach: jako magiczny tekst w Dart, jako logika triggerów SQL i jako typowany wariant protokołu. Kod wykonawczy przyjmuje zwykłą wiadomość tekstową z odpowiednim prefiksem jako autorytatywne polecenie zmiany stanu relacji. Pole `preserveHistory` pochodzi od nadawcy i wpływa na dane lokalne odbiorcy.

**Scenariusz:** 1. Złośliwy, ale prawidłowo sparowany kontakt wysyła zwykłą wiadomość, której body zaczyna się od magicznego prefiksu i zawiera `preserveHistory=false`. 2. Odbiorca poprawnie uwierzytelnia peer i odszyfrowuje MLS. 3. Podczas zapisu wiadomości trigger SQL traktuje treść jako polecenie usunięcia relacji. 4. Kontakt zostaje zablokowany, kolejki anulowane, MLS i endpointy usunięte, a historia lokalna może zostać skasowana. Osobno, gdy prawidłwy komunikat usunięcia nie zostanie zakolejkowany, UI i tak usuwa relację lokalnie, tworząc trwałą asymetrię.

**Wpływ:** Utrata lokalnej historii rozmowy zależna od danych kontrolowanych przez zdalny kontakt; możliwość wymuszenia rozłączenia; rozjazd stanu obu stron po błędzie sieci; bardzo trudne do odtworzenia przypadki po crashu. To nie jest błąd kryptografii MLS, lecz błąd autoryzacji semantyki po odszyfrowaniu.

**Przyczyna:** Brak jednego, jawnego process managera relacji. Logika domenowa została rozproszona pomiędzy UI, SQL i payload aplikacyjny, a polityka lokalnej retencji została pomylona z informacją zdalną.

**Rekomendacja:** Usunąć rozpoznawanie magicznego prefiksu z tabeli `messages`. Dodać typowane polecenie silnika `requestRelationshipRemoval` i trwały workflow: lokalny tombstone + typed outbox + unikalny `relationshipEpoch`/`removalId` + zdalne ACK. Zdalny payload może informować o zakończeniu relacji, ale nie może wybierać polityki kasowania lokalnej historii; odbiorca powinien zawsze użyć własnej polityki. Przejście lokalne i zapis outboxu muszą być jednym commitem.

**Test regresyjny:** Dwa sparowane klienty. Wyślij zwykłą wiadomość o treści identycznej z dawnym prefiksem i potwierdź, że pozostaje zwykłą wiadomością. Następnie wykonaj typowane usunięcie, zasymuluj crash po lokalnym commicie przed wysłaniem, uruchom ponownie i sprawdź idempotentne dostarczenie. Zdalne `preserveHistory=false` nie może skasować historii odbiorcy.

**Ryzyko zmiany:** Migracja musi rozpoznać istniejące tombstone’y i niedostarczone stare wiadomości. Przez okres kompatybilności odbieranie starego formatu powinno tworzyć wyłącznie bezpieczny, zachowujący historię tombstone, nigdy kasować historii. Wersję protokołu należy podnieść lub dodać capability negocjacji.

---

## TC-002 — Błąd wysłania receipt po udanym commicie odbioru powoduje ACK `Rejected` i kryptograficzne zablokowanie peera

**Severity:** HIGH  
**Priority:** P0  
**Confidence:** high  
**Effort:** M  
**Kategoria:** Crash consistency / semantyka ACK

**Dowód:**
- `common/torchat-client-engine/src/actor/application_envelope.rs:102-135` — transakcja zapisuje wiadomość, delivery receipt, nowy snapshot MLS i rekord deduplikacji.
- `common/torchat-client-engine/src/actor/application_envelope.rs:374-382` — po udanym commicie funkcja wywołuje `flush_pending_receipt_effects()?`; błąd jest propagowany jak błąd całego odbioru.
- `common/torchat-client-engine/src/actor/peer_events.rs:55-90` — każdy błąd `handle_application_envelope` oznacza zapis `REJECTED`, ACK `Rejected` i dodanie nadawcy do `crypto_blocked_peers`.

**Opis:** Odbiór wiadomości ma poprawną transakcję domenową, lecz po niej wykonywany jest dodatkowy efekt wysyłki receipt. Jeśli przygotowanie lub dispatch receipt zawiedzie, warstwa P2P nie rozróżnia błędu efektu pobocznego od błędu deszyfrowania/commitu. Wiadomość i MLS są już utrwalone, ale peer otrzymuje semantykę odrzucenia.

**Scenariusz:** 1. Odbiorca zapisuje wiadomość, dedupe, receipt i post-decryption MLS snapshot. 2. Baza lub transport odmawia podczas `flush_pending_receipt_effects`. 3. `handle_application_envelope` zwraca `Err`. 4. P2P oznacza envelope jako odrzucony, wysyła `Rejected` i blokuje kontakt kryptograficznie. 5. Nadawca może oznaczyć wiadomość jako failed, choć odbiorca ją widzi; kolejne poprawne wiadomości zostają zablokowane.

**Wpływ:** Fałszywy błąd dostarczenia, trwałe rozjechanie stanu UX, niepotrzebny re-pairing i blokada całej sesji MLS z powodu awarii receipt. To narusza invariant: po commicie aplikacyjnym wynik transportowy nie może zostać cofnięty przez efekt poboczny.

**Przyczyna:** Brak jawnej granicy „commit point” w API `handle_application_envelope` oraz zbyt szerokie mapowanie każdego `Err` na błąd kryptograficzny.

**Rekomendacja:** Zwracać strukturalny wynik `InboundApplyResult { committed, events, receipt_due }`. Po commicie aplikacyjnym zawsze zakończyć inbound envelope jako `Delivered`/`Persisted`. Receipt pozostawić w trwałej kolejce i retry; błędy flush logować i klasyfikować, ale nie propagować do ACK wiadomości. `crypto_blocked_peers` ustawiać wyłącznie dla błędów uwierzytelnienia, hash mismatch lub nieodwracalnej desynchronizacji MLS.

**Test regresyjny:** Wstrzyknąć błąd dokładnie po commicie wiadomości, podczas pobrania lub wysyłki receipt. Odbiorca ma widzieć jedną wiadomość, MLS ma pozostać na nowej generacji, ACK ma być `Delivered`, peer nie może trafić do `crypto_blocked_peers`, a receipt ma zostać wysłany po restarcie.

**Ryzyko zmiany:** Zmiana semantyki ACK może ujawnić ukryte założenia w senderze. Wprowadzić nowy test kontraktowy P2P i telemetryczny licznik `receipt_queue_failed_after_commit`; migracja danych nie jest potrzebna.

---

## TC-003 — Desktop przechowuje klucz tożsamości w jawnym pliku i wyprowadza z niego klucz SQLCipher

**Severity:** HIGH  
**Priority:** P0  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Kryptografia / lokalne sekrety

**Dowód:**
- `desktop/src/identity_store.rs:16-47` — 32-bajtowy klucz prywatny jest zapisany jako Base64 w `installation.key`; tylko Unix otrzymuje `0600`, brak odpowiednika dla Windows.
- `desktop/src/runtime_engine_stdio.rs:38-43` — klucz bazy to `SHA-256(domain || identity_private_key)`.
- `desktop/src/runtime_engine_stdio.rs:73-89` — ten sam sekret jest ładowany do konfiguracji jako tożsamość i materiał do wyprowadzenia klucza bazy.
- `mobile/android/app/src/main/kotlin/org/torchat/security/LocalSecretStore.kt:12-49` — Android ma lepszy wzorzec: dwa niezależne losowe sekrety opakowane kluczem Android Keystore.

**Opis:** Na desktopie kompromitacja jednego pliku daje jednocześnie długoterminową tożsamość użytkownika oraz deterministyczny klucz odszyfrowujący bazę. Uprawnienia `0600` chronią jedynie część scenariuszy Unix i nie zabezpieczają Windows ani malware działającego w kontekście użytkownika.

**Scenariusz:** Malware, backup w chmurze, inny proces użytkownika lub błędna kopia diagnostyczna odczytuje `installation.key`. Atakujący może podszyć się pod tożsamość i wyliczyć klucz SQLCipher do skopiowanej bazy. Rotacja jednego sekretu wymusza jednocześnie migrację obu funkcji.

**Wpływ:** Utrata poufności lokalnej historii i przejęcie tożsamości z jednego artefaktu; brak rozdziału domen kryptograficznych; większy blast radius na Windows.

**Przyczyna:** Uproszczony model PoC bez OS credential vault i bez niezależnego losowego klucza bazy.

**Rekomendacja:** Przechowywać klucz tożsamości i losowy klucz SQLCipher jako dwa niezależne sekrety w DPAPI/Credential Manager na Windows, Secret Service/KWallet na Linux i Keychain na macOS. Plik bazy powinien używać losowego 256-bitowego klucza, nie KDF z klucza podpisu. Dodać atomiczną migrację: odczyt starego pliku → zapis do vault → `PRAGMA rekey` → weryfikacja → bezpieczne usunięcie starego pliku. Używać `Zeroizing`/`SecretBytes` na całej ścieżce.

**Test regresyjny:** Test migracji ze starego layoutu, przerwanie procesu przed i po `rekey`, ponowne uruchomienie, brak utraty tożsamości i danych. Test Windows potwierdzający ACL/vault oraz brak sekretu w plaintext w katalogu danych.

**Ryzyko zmiany:** Największe ryzyko to utrata dostępu po nieatomowej migracji lub niedostępny vault w sesjach headless. Wymagany journal migracji i możliwość bezpiecznego rollbacku bez pozostawiania dwóch aktywnych kopii.

---

## TC-004 — Konfiguracja host/staging nie dostarcza wymaganego `TORCHAT_PAIRING_SECRET` i serwer kończy proces podczas startu

**Severity:** HIGH  
**Priority:** P0  
**Confidence:** high  
**Effort:** S  
**Kategoria:** Operacyjność / deployment

**Dowód:**
- `server/torchat-server/src/main.rs:283-290` — konstrukcja `AppState` używa `expect("TORCHAT_PAIRING_SECRET is required")`.
- `infra/docker/compose.host.yml:1-19,55-59` — host compose przekazuje sekret bazy, lecz nie deklaruje `TORCHAT_PAIRING_SECRET` ani pliku sekretu.
- `infra/host/bootstrap-staging.sh:19-31` — bootstrap generuje `postgres_password` i `database_url`, ale nie pairing secret.
- `infra/docker/compose.dev.yml:6-13` — konfiguracja developerska poprawnie wymaga zmiennej.

**Opis:** Ścieżka produkcyjna host/staging i kod serwera mają sprzeczny kontrakt konfiguracji. Docker Compose nie przekazuje arbitralnych zmiennych hosta do kontenera, jeśli nie zostały zadeklarowane.

**Scenariusz:** Operator wykonuje udokumentowany bootstrap, ustawia `TORCHAT_ONION_URL` i uruchamia usługę. Kontener serwera dociera do inicjalizacji `AppState`, nie znajduje zmiennej i panikuje. Tor czeka na usługę, deployment pozostaje niedostępny.

**Wpływ:** Powtarzalna awaria startu środowiska host/staging; brak bezpiecznego release gate dla rzeczywistej konfiguracji.

**Przyczyna:** Dev i host compose ewoluowały osobno; serwer wspiera `_FILE` dla URL bazy, ale nie dla pairing secret.

**Rekomendacja:** Dodać `TORCHAT_PAIRING_SECRET_FILE`, wygenerować 32+ bajtowy sekret w bootstrapie, zamontować jako Docker secret i przekazać ścieżkę do serwera. Dodać walidator konfiguracji uruchamiany przed migracjami oraz smoke test `docker compose -f compose.host.yml config` + start/health w CI.

**Test regresyjny:** Uruchomienie host compose z nowym pustym secure root powinno samodzielnie utworzyć sekrety, wystartować serwer i przejść `/health`. Brak lub zbyt krótki pairing secret ma dawać czytelny błąd preflight, nie panic po częściowej inicjalizacji.

**Ryzyko zmiany:** Zmiana sekretu unieważnia hashe kodów/capabilities zależne od tego sekretu. Na istniejącym środowisku należy zachować wartość, nie generować ponownie.

---

## TC-005 — Idempotency `command_id` ginie na desktopie, a Android tworzy nowy identyfikator dla każdego wywołania

**Severity:** HIGH  
**Priority:** P0  
**Confidence:** high  
**Effort:** M  
**Kategoria:** API / niezawodność po timeoutach

**Dowód:**
- `mobile/lib/windows_runtime.dart:558-566` — host Dart wysyła `requestId` i `commandId`.
- `desktop/src/runtime_engine_stdio.rs:125-140` — sidecar deserializuje envelope, ale wywołuje `engine.submit(request_id, command)`, odrzucając `command_id`.
- `common/torchat-client-engine/src/engine.rs:64-86` — `submit` jawnie ustawia `command_id: None`; `submit_envelope` jest przeznaczone do zachowania idempotency.
- `mobile/android/app/src/main/kotlin/org/torchat/mobile/AndroidEngineHost.kt:30-35,57-68` — `commandId=requestId`, a `requestId` jest nowym UUID dla każdego await.

**Opis:** Silnik ma trwałą tabelę `processed_commands` i wiąże identyfikator z hashem całego payloadu, lecz hosty nie zapewniają stabilnego identyfikatora logicznej operacji. Na desktopie identyfikator jest całkowicie tracony. Na Androidzie ponowienie po timeout/restart traktowane jest jak nowe polecenie.

**Scenariusz:** UI wysyła mutację, commit dochodzi do skutku, ale odpowiedź ginie przy restarcie Activity/sidecara. UI ponawia operację. Desktop nie ma idempotency, Android generuje nowy UUID; silnik wykonuje drugi commit lub drugi efekt zewnętrzny. Dotyczy m.in. send, pairing, rotacji capability, usuwania relacji i zmian profilu.

**Wpływ:** Duplikaty, wyścigi, ponowne przesunięcia workflow i trudne do rozstrzygnięcia sukcesy po timeoutach. Zabezpieczenie istniejące w bazie nie działa end-to-end.

**Przyczyna:** Pomieszanie korelacji pojedynczego requestu z idempotency logicznej intencji użytkownika.

**Rekomendacja:** Desktop ma używać `submit_envelope(envelope)`. W kontrakcie rozdzielić `requestId` od `operationId/commandId`. Dla mutacji generować stabilny ID w warstwie repository/process manager, zapisać go lokalnie przed wywołaniem i zachowywać przez retry/restart; zapytania mogą nie mieć command ID. Dodać TTL/retencję wyników po ustalonym oknie retry.

**Test regresyjny:** Dla każdej mutacji: commit, zgubienie odpowiedzi, ponowienie z tym samym operation ID po restarcie hosta. Oczekiwany ten sam wynik i jeden efekt. Ponowienie z tym samym ID, ale innym payloadem ma zwrócić `idempotency_conflict` na Windows, Androidzie i bezpośrednim FFI.

**Ryzyko zmiany:** Po wdrożeniu starsze hosty nadal będą wysyłały niestabilne ID. Wersjonować engine contract i wspierać okres przejściowy; nie używać request ID jako substytutu dla operacji rozpoczętej przed restartem.

---

## TC-006 — UI blokuje dostęp do lokalnych danych, dopóki Tor, listener, onion service i relay nie są jednocześnie gotowe

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** Mobile/UI / model gotowości

**Dowód:**
- `mobile/lib/app/sequential_app_controller.dart:144-197` — po odczycie snapshotu ekran pozostaje `boot`; sekwencja czeka kolejno na Tor, peer listener, onion service i relay.
- `mobile/lib/app/app_controller_base.dart:801-868` — komunikacja pozostaje pending bez relay nawet przy gotowym endpoint P2P.
- `mobile/lib/app/app_controller_base.dart:872-891` — przejście do main wymaga `transport.connected`, gotowego peer servera i wszystkich kroków `ready`.

**Opis:** Aplikacja poprawnie rozróżnia komponenty transportu w modelu, ale na końcu łączy je w jeden twardy gate. Zaszyfrowana baza i snapshot aplikacji są dostępne wcześniej, jednak użytkownik nie może wejść do historii, ustawień ani diagnostyki operacyjnej.

**Scenariusz:** Tor lokalny działa, ale relay ma awarię albo onion service nie może się opublikować z powodu ograniczenia tła. Użytkownik ma w pełni czytelną lokalną bazę, lecz pozostaje na ekranie boot. Podobnie relay może działać, a P2P być chwilowo niedostępny; lokalne funkcje są niepotrzebnie zablokowane.

**Wpływ:** Zły UX offline, utrudniony dostęp do własnych danych, mylenie control plane z data plane i większa skłonność użytkownika do restartów/wyłączania aplikacji.

**Przyczyna:** Brak osobnych capability gates dla „local usable”, „pairing available”, „relay available” i „peer reachable”.

**Rekomendacja:** Po `engine_ready && local_data_ready` otwierać główny shell w trybie offline/degraded. Osobno prezentować gotowość Tor, listenera, onion, relay i konkretnego kontaktu. Blokować tylko operacje, które faktycznie wymagają danego komponentu: pairing/profil relayem, P2P send endpointem, relay fallback sesją relay.

**Test regresyjny:** Start z zaszyfrowaną historią przy niedostępnym relay: main screen i historia są dostępne, send pokazuje queued/degraded. Start bez onion service, ale z polityką relay-only: relayowe operacje działają. Start bez relay, ale z aktywną sesją P2P: wiadomość może zostać wysłana P2P.

**Ryzyko zmiany:** UI musi przestać utożsamiać jeden status z całym systemem. Migrację wykonać najpierw na warstwie modelu gotowości, potem zmienić routing ekranów; nie usuwać diagnostycznej osi czasu.

---

## TC-007 — Snapshoty MLS nie mają ochrony przed rollbackiem starszej kopii bazy

**Severity:** HIGH  
**Priority:** P1  
**Confidence:** medium  
**Effort:** L  
**Kategoria:** Kryptografia / backup i recovery

**Dowód:**
- `common/torchat-core/src/mls.rs:38-57,89-151,201-264` — cały stan provider `MemoryStorage` i signer jest serializowany do własnego snapshotu `TCMEM1`.
- `common/torchat-client-engine/sql/migrations/001_canonical_client.sql:24-31` — jedynym trwałym kotwiczeniem konwersacji jest rekord `conversation_mls` w tej samej bazie.
- `common/torchat-client-engine/src/actor/mod.rs:1118-1139` — przy starcie actor bezwarunkowo odtwarza snapshoty z bazy; brak zewnętrznego monotonic counter/epoch.

**Opis:** Crash rollback pojedynczej transakcji jest obsłużony, lecz przywrócenie starszej kopii całej zaszyfrowanej bazy cofa również MLS i wszystkie lokalne wskaźniki. Repozytorium nie zawiera niezależnej kotwicy pozwalającej wykryć, że snapshot był już historycznie zastąpiony nowszym.

**Scenariusz:** Użytkownik przywraca backup katalogu aplikacji lub narzędzie synchronizacji nadpisuje DB starszą wersją. Silnik poprawnie odszyfrowuje bazę i ładuje historyczny MLS state. Kolejne wiadomości mogą być nieodszyfrowywalne, kontakt trafi do crypto-block, a zachowanie zależy od właściwości OpenMLS przy cofniętej generacji.

**Wpływ:** Trwała desynchronizacja MLS i możliwe naruszenie oczekiwanej ochrony post-compromise/forward secrecy. Nie potwierdzono w dostarczonym materiale konkretnego wykorzystania poufności — to ryzyko architektoniczne wymagające testu z właściwościami OpenMLS.

**Przyczyna:** Backup/recovery został utożsamiony z odtworzeniem bajtów SQLCipher bez modelu anti-rollback dla stanu kryptograficznego.

**Rekomendacja:** Dodać per-relationship monotonic `mls_state_version` oraz zewnętrzną kotwicę w OS secure storage, ewentualnie podpisany checkpoint synchronizowany z peerem. Snapshot envelope powinien zawierać protocol/library/schema version, group ID i epoch. Przy wykryciu rollbacku zatrzymać deszyfrowanie i wymagać kontrolowanego recovery/re-pair, nie próbować „naprawiać” stanu.

**Test regresyjny:** Utworzyć konwersację, wymienić N wiadomości, zachować snapshot z N-2, następnie podmienić DB i uruchomić klienta. Oczekiwane jawne wykrycie rollbacku przed wysłaniem/odszyfrowaniem. Dodać testy kompatybilności backup/rekey i dokumentowaną politykę odzyskiwania.

**Ryzyko zmiany:** Secure-store counter może sam zostać utracony podczas migracji urządzenia. Projekt musi rozróżnić legalny restore na nowym urządzeniu od rollbacku; dla 0.1 można jawnie nie wspierać restore i wymagać re-pair.

---

## TC-008 — Read receipts są częścią publicznego kontraktu i UI, ale engine zawsze odrzuca je jako `Unsupported`

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** Niespójność kontraktu produktu

**Dowód:**
- `common/client-engine-contract.json:1-231` — publiczne `sendReadReceipts`, event/state `READ`.
- `common/torchat-client-engine/src/actor/command_dispatch.rs:376-390` — komenda buduje `ApplicationPayloadV1::ReadReceipt`.
- `common/torchat-client-engine/src/actor/mod.rs:660-691` — dla wszystkich nie-capability „ephemeral” stała `EPHEMERAL_MLS_DELIVERY_SAFE=false` zwraca `Unsupported`.
- `mobile/lib/core/runtime/runtime_repository.dart:786-798` — UI wywołuje receipt po focus i po cichu przechwytuje każdy błąd.

**Opis:** Decyzja o wyłączeniu lossy MLS frames jest poprawna kryptograficznie, ale kontrakt produktu nie odzwierciedla tej decyzji. UI traktuje operację jako wykonaną i ukrywa błąd.

**Scenariusz:** Odbiorca otwiera rozmowę. Lokalny focus zostaje ustawiony, potem `sendReadReceipts` zwraca unsupported. Catch ignoruje wynik. Nadawca nigdy nie otrzymuje READ, mimo że modele i UI mogą pokazywać tę funkcję jako dostępną.

**Wpływ:** Niespójne stany wiadomości i trudne testowanie; użytkownik nie może odróżnić „wyłączone” od „chwilowo niedostarczone”.

**Przyczyna:** Feature flag istnieje wewnątrz implementacji, nie w negocjowanym kontrakcie/capabilities.

**Rekomendacja:** Dla 0.1 wybrać jedną drogę: usunąć/hide `sendReadReceipts` i READ z aktywnego manifestu capability albo wdrożyć receipt jako trwałą, uporządkowaną ramkę korzystającą z tego samego MLS outboxu co wiadomości. Nie stosować best-effort po kanale, który przesuwa ratchet.

**Test regresyjny:** Contract test ma sprawdzać, że każda publiczna operacja jest albo wykonywalna, albo jawnie oznaczona `disabled` z powodem i UI jej nie wywołuje. Dla implementacji trwałej: utrata ACK, restart po encryption, duplikat receipt i receipt wyprzedzający lokalny zapis.

**Ryzyko zmiany:** Usunięcie READ może wymagać migracji UI i modeli. Implementacja trwała zwiększa obciążenie kolejki i musi zachować globalne uporządkowanie MLS z wiadomościami i capability frames.

---

## TC-009 — Retry jest deterministyczny, bez jittera i bez ogólnego dead-letter/permanent-failure lifecycle

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** System rozproszony / retry

**Dowód:**
- `common/torchat-client-engine/src/actor/mod.rs:1101-1104` — `5s * 2^min(attempt,5)`, bez losowości.
- `common/torchat-client-engine/src/actor/connection.rs:348-363` — relay retry 3/5/8/12/15 sekund, również deterministyczny.
- `common/torchat-client-engine/sql/migrations/001_canonical_client.sql:56-105` oraz migracje 007-021 — wiele kolejek ma `attempt_count`, `next_attempt_at`, `last_error`, ale brak wspólnego `DEAD_LETTER`, `permanent_reason` i limitu wieku/prób.

**Opis:** Kolejki są trwałe i claimowane, co jest dobrą bazą, ale ich scheduler nigdy systemowo nie kończy poison itemów. Po wspólnej awarii wszystkie klienty wracają w tych samych interwałach.

**Scenariusz:** Relay wraca po awarii albo endpoint kontaktu jest permanentnie niepoprawny. Tysiące klientów wykonują próby w tych samych sekundach. Poison capability/welcome jest ponawiany bez końca, tabela rośnie, logi się powtarzają i koszt startup recovery rośnie.

**Wpływ:** Thundering herd, retry storms, zużycie baterii i nieograniczony dług operacyjny w bazie. Użytkownik nie dostaje rozstrzygnięcia błędu permanentnego.

**Przyczyna:** Retry policy jest helperem liczbowym, nie jawnie modelowanym kontraktem błędów i lifecycle kolejki.

**Rekomendacja:** Wprowadzić wspólny `RetryPolicy` z Full Jitter, maksymalnym opóźnieniem, limitem prób/age i klasyfikacją transient/permanent/auth/protocol. Każda kolejka powinna mieć `state`, `claimed_until`, `last_error_code`, `dead_lettered_at`. Dead-letter ma być widoczny w diagnostyce i możliwy do ręcznego retry po zmianie warunków.

**Test regresyjny:** Deterministyczny clock i RNG: rozkład jittera w granicach, przejście do dead-letter po limicie, brak retry permanentnego frame-too-large, reset backoff po nowym endpoint/capability, recovery claim po crashu.

**Ryzyko zmiany:** Zmiana deadline’ów może opóźnić istniejące rekordy. Migrować bez kasowania, wyliczając stan na podstawie attempt_count/age; zachować specjalne reguły dla wiadomości użytkownika.

---

## TC-010 — Kolejka relay-control jest nieograniczona i używa `Vec::remove(0)`

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** S  
**Kategoria:** Współbieżność / backpressure

**Dowód:**
- `common/torchat-client-engine/src/actor/mod.rs:147-178,286-287` — actor przechowuje `Vec<PendingRelayControl>` i tworzy dwa `mpsc::unbounded_channel` dla outcome’ów.
- `common/torchat-client-engine/src/actor/connection.rs:84-91` — pobranie następnego elementu wykonuje `remove(0)`.
- `common/torchat-client-engine/src/actor/mod.rs:429-439` — publiczne relay-control commands są dopisywane do kolejki; deduplikacja obejmuje tylko część wewnętrznych operacji.

**Opis:** Główne kanały engine i peer są bounded, lecz control plane ma wyjątek bez limitu. `remove(0)` przesuwa wszystkie elementy, więc koszt rośnie liniowo z backlogiem.

**Scenariusz:** UI lub błędny klient szybko wysyła setNickname/refresh/submit/cancel/inbox, podczas gdy Tor HTTP blokuje się na timeoutach. Kolejka rośnie w pamięci, każdy dequeue kopiuje/przesuwa elementy, a outcome channel również nie ma backpressure.

**Wpływ:** Wzrost pamięci i czasu actor loop; możliwość lokalnego DoS przez host/UI; gorszy startup/reconnect.

**Przyczyna:** Control worker został dodany jako boczna ścieżka po optymalizacji actor loop, bez tej samej polityki capacity co reszta engine.

**Rekomendacja:** Użyć `VecDeque`, bounded mpsc i stałej capacity. Deduplikować/coalesce operacje po kluczu (`setNickname` latest, inbox refresh singleton, confirm/ack by ID), a publicznemu callerowi zwracać `busy/backpressure` zamiast nieskończonego enqueue.

**Test regresyjny:** Zablokowany worker + więcej poleceń niż capacity: pamięć pozostaje bounded, singletony są scalone, mutacje nie zmieniają kolejności, caller dostaje jawny błąd.

**Ryzyko zmiany:** Backpressure zmieni zachowanie hosta; UI musi rozpoznawać `busy` i retry z jitterem, nie zapętlać natychmiast.

---

## TC-011 — Relay loguje surowe identyfikatory obu stron i message ID, tworząc trwały zapis grafu społecznego

**Severity:** HIGH  
**Priority:** P1  
**Confidence:** high  
**Effort:** S  
**Kategoria:** Prywatność / observability

**Dowód:**
- `server/torchat-server/src/main.rs:1159-1183,1213-1225,1318-1322` — logi sesji zawierają pełny `installation_id` i connection IDs.
- `server/torchat-server/src/main.rs:1332-1339` — każdy envelope loguje sender, recipient i message ID w jednym rekordzie.
- `server/torchat-server/src/main.rs:1373-1435` — walidacja, queue full, forwarded, write failed i offline ponownie logują te same identyfikatory.

**Opis:** Treść jest E2E zaszyfrowana, ale standardowy `RUST_LOG=info` utrwala najcenniejsze metadane: kto, do kogo i kiedy wysłał konkretny envelope. Nie znaleziono serwerowej sanitizacji analogicznej do diagnostyki klienta.

**Scenariusz:** Operator, agregator logów, backup logów lub włamanie do systemu obserwowalności uzyskuje historię par kontaktów, częstotliwość komunikacji, status online i korelację message IDs. Retencja logów może być dłuższa niż retencja bazy relay.

**Wpływ:** Naruszenie głównej obietnicy privacy-first mimo poprawnego E2E. Tor ukrywa trasę sieciową, ale relay nadal zna logiczne identyfikatory sesji; logi utrwalają tę wiedzę.

**Przyczyna:** Logi diagnostyczne zostały zaprojektowane pod debugowanie routingu, bez threat modelu metadanych serwera.

**Rekomendacja:** Na poziomie info używać liczników i per-process pseudonimów/HMAC z rotowanym kluczem, nigdy sender+recipient w jednym rekordzie. Surowe IDs tylko w lokalnym, opt-in secure debug z krótką retencją. Zdefiniować politykę retencji, dostęp i automatyczny test sanitizacji serwera.

**Test regresyjny:** Test capture tracing: typowy send, offline i queue-full nie mogą zawierać installation IDs, onion, message ID ani nickname. Dopuszczalne są rotowane pseudonimy niełączliwe między okresami.

**Ryzyko zmiany:** Pseudonimizacja utrudni korelację incydentów. Zachować request correlation generowane po stronie serwera, nie oparte na trwałej tożsamości.

---

## TC-012 — Relay nie jest bezpieczny dla wielu instancji: challenge, połączenia, rate state i routing są procesowe

**Severity:** HIGH  
**Priority:** P1  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Serwer / skalowanie i dostępność

**Dowód:**
- `server/torchat-server/src/main.rs:89-99` — challenges, installations cache, connections i pairing_attempts są `HashMap` w pamięci procesu.
- `server/torchat-server/src/main.rs:1159-1178` — jedna sesja na installation jest zastępowana wyłącznie w lokalnej mapie.
- `server/torchat-server/src/main.rs:1362-1443` — routing odbiorcy przeszukuje tylko lokalne `connections`.

**Opis:** Serwer działa poprawnie jako pojedyncza instancja. Za load balancerem stan control i data plane nie jest współdzielony. Sama baza PostgreSQL nie rozwiązuje aktywnych WebSocketów ani challenge.

**Scenariusz:** Challenge powstaje na instancji A, rejestracja trafia do B i kończy się not found. Nadawca ma WebSocket na A, odbiorca na B; A zwraca recipient offline. Rolling deploy zamyka wszystkie lokalne sesje, a druga instancja nie przejmuje routingu. Rate limit można obchodzić rozpraszając żądania.

**Wpływ:** Fałszywy offline, niestabilny pairing, brak rolling deploymentu i ukryta bariera skalowania. To ryzyko staje się realnym błędem natychmiast po uruchomieniu >1 repliki.

**Przyczyna:** Brak jawnego inwariantu deploymentu „single instance” i brak rozproszonego registry/pub-sub.

**Rekomendacja:** Dla 0.1 jawnie wymusić jedną replikę i readiness, aby orkiestrator nie uruchomił równoległych instancji. Docelowo przenieść challenge/rate state do Redis/Postgres z atomowymi TTL, aktywne połączenia rejestrować z instance ID/lease, a envelope routować przez pub-sub/stream do właściciela WebSocket. Sticky sessions nie wystarczą dla nadawca→odbiorca.

**Test regresyjny:** Dwie instancje: challenge na A/rejestracja na B; sender A/recipient B; zastąpienie sesji; restart A podczas forward. Wszystkie przypadki muszą mieć jednoznaczną semantykę.

**Ryzyko zmiany:** Warstwa pub-sub zwiększa metadane i złożoność. Najpierw utrwalić single-instance jako wspierany model, a multi-instance zaprojektować świadomie.

---

## TC-013 — Niezalogowane endpointy bootstrap/session nie mają skutecznego per-origin ani globalnego concurrency budget

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** Serwer / abuse i DoS

**Dowód:**
- `server/torchat-server/src/main.rs:420-448` — challenge ma jedynie globalny limit liczby wpisów i TTL.
- `server/torchat-server/src/main.rs:451-465` — rejestracja wykonuje weryfikację podpisu po pobraniu challenge.
- `server/torchat-server/src/main.rs:328-357` — Router ma limit body 16 KiB, ale brak timeout/concurrency/rate middleware.
- `server/torchat-server/src/main.rs:641-713` — pairing rate jest dopiero po autoryzacji i per sender.

**Opis:** Limit rozmiaru wejścia jest poprawny, lecz atakujący może wielokrotnie wypełniać pulę challenge, wymuszać weryfikacje kryptograficzne i otwierać WebSockety. Przy Torze klasyczny per-IP limit może nie być użyteczny, więc potrzebne są budżety niezależne od adresu.

**Scenariusz:** Bot przez Tor generuje 10k challenge, utrzymuje pulę blisko limitu i odświeża po TTL. Legalni klienci dostają 429. Równolegle wysyła niepoprawne proof/session i zajmuje CPU/DB. Na wielu instancjach każdy proces ma osobny limit.

**Wpływ:** Tani DoS control plane, szczególnie przy małym relay. Brak mechanizmu odcięcia kosztownych klientów przed kryptografią/DB.

**Przyczyna:** Abuse prevention ogranicza się do body size i jednej mapy capacity.

**Rekomendacja:** Dodać globalne semafory dla bootstrap crypto, DB i upgrade’ów, deadline middleware, limit aktywnych/nowych WebSocketów, budżet challenge per anonimowy token oraz ewentualnie lekki proof-of-work/adaptive puzzle. Limity muszą uwzględniać Tor i nie polegać wyłącznie na IP. Eksponować metryki odrzuceń bez surowych IDs.

**Test regresyjny:** Load test nieautoryzowanych challenge/proof/ws; legalny klient zachowuje bounded latency, pamięć i liczbę zadań. Test limitów na jednej i dwóch instancjach.

**Ryzyko zmiany:** Zbyt agresywne limity zaszkodzą klientom na wolnych obwodach Tor. Używać dłuższych timeoutów protokołu, lecz bounded concurrency.

---

## TC-014 — Format snapshotu MLS zależy od prywatnego layoutu `openmls_memory_storage` i nie ma planu migracji wersji

**Severity:** MEDIUM  
**Priority:** P2  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Kryptografia / kompatybilność danych

**Dowód:**
- `common/torchat-core/src/mls.rs:38-57` — własny provider bezpośrednio używa `MemoryStorage`.
- `common/torchat-core/src/mls.rs:89-151,201-264` — serializacja iteruje po `storage.values` i odtwarza je do mapy pod nagłówkiem `TCMEM1`.
- `Cargo.lock` — OpenMLS 0.8.1, `openmls_memory_storage` 0.5.0 i powiązany stos crypto.

**Opis:** Snapshot jest kompletny i działa dla bieżącej wersji, ale jego stabilność zależy od kluczy/wartości wewnętrznego storage OpenMLS. Nagłówek rozpoznaje tylko własny format, nie wersję biblioteki, ciphersuite ani migrator.

**Scenariusz:** Aktualizacja OpenMLS zmienia klucze storage, serializację signer/group lub wymagania provider. Nowy klient otwiera bazę, nagłówek TCMEM1 jest poprawny, ale `SignatureKeyPair::read` lub `MlsGroup::load` nie potrafi odtworzyć stanu. Użytkownik traci możliwość odszyfrowania nowych wiadomości.

**Wpływ:** Ryzyko nieodwracalnej utraty konwersacji przy aktualizacji zależności; blokada bezpiecznych security upgrades.

**Przyczyna:** PoC-owy snapshot provider internals zamiast jawnie wersjonowanego storage contract.

**Rekomendacja:** Dodać envelope `MlsSnapshotVn` z app schema, OpenMLS version, suite, group ID/epoch i checksum. Zbudować golden fixtures dla każdej wydanej wersji oraz migrator offline. Rozważyć wspierany storage provider OpenMLS lub własny adapter z publicznym, stabilnym schematem zamiast bezpośredniego dostępu do `.values`.

**Test regresyjny:** Każde wydanie musi otwierać golden snapshot poprzedniej wersji i kontynuować wymianę wiadomości z peerem. Test niedozwolonego downgrade i uszkodzonego snapshotu.

**Ryzyko zmiany:** Migracja stanu MLS jest kryptograficznie wrażliwa; nie rekonstruować brakujących kluczy. Gdy migracja nie jest pewna, wymusić bezpieczny re-pair z jawnym komunikatem.

---

## TC-015 — `processed_commands` nie ma polityki retencji ani cleanupu

**Severity:** MEDIUM  
**Priority:** P2  
**Confidence:** high  
**Effort:** S  
**Kategoria:** Storage / wzrost danych

**Dowód:**
- `common/torchat-client-engine/sql/migrations/016_projection_consistency.sql:16-25` — tabela przechowuje command type, pełny result JSON, revision i created_at.
- `common/torchat-client-engine/src/storage/sqlite/projection.rs:4-46` — są tylko load/save; brak delete/prune.
- `common/torchat-client-engine/src/actor/mod.rs:405-457` — odczyt przy każdym command ID i zapis wyniku po sukcesie.

**Opis:** Trwała idempotency jest wartościowa, lecz wszystkie historyczne wyniki mutacji pozostają bezterminowo w bazie. Nie ma limitu czasu, liczby ani rozmiaru.

**Scenariusz:** Długo używany klient generuje setki tysięcy operation IDs, zwłaszcza jeśli host używa request ID dla każdej próby. Tabela i indeks rosną, backup/rekey/startup są cięższe, a wynik JSON utrwala dane dłużej niż domenowe rekordy.

**Wpływ:** Wzrost bazy, dodatkowa retencja metadanych i koszt maintenance.

**Przyczyna:** Idempotency store został dodany bez formalnego retry horizon.

**Rekomendacja:** Ustalić maksymalne okno ponowienia (np. 30–90 dni dla krytycznych mutacji, krótsze dla innych), okresowo usuwać pełny result, pozostawiając opcjonalny hash/tombstone do wykrycia konfliktu. Limitować wielkość result JSON i raportować rozmiar.

**Test regresyjny:** Prune nie może usunąć wpisu w aktywnym oknie retry; po usunięciu starego pełnego wyniku konflikt tego samego ID z innym payloadem nadal jest wykrywalny, jeśli zachowano tombstone.

**Ryzyko zmiany:** Zbyt krótka retencja dopuści ponowne wykonanie bardzo starej operacji. Polityka musi być dłuższa od maksymalnego wspieranego offline/retry.

---

## TC-016 — Krytyczna logika relacji jest ukryta w 412-liniowej migracji triggerów i zdublowana w Rust

**Severity:** MEDIUM  
**Priority:** P2  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Architektura / storage

**Dowód:**
- `common/torchat-client-engine/sql/migrations/014_runtime_integrity.sql:1-412` — triggery zapisują timestampy stanów, granice relacji, rozpoznają wiadomości systemowe, blokują kontakty i kasują wiele tabel.
- `common/torchat-client-engine/src/storage/runtime_storage.rs:521-597` — lokalne `remove_relationship` wykonuje podobną sekwencję w Rust.
- `common/torchat-client-engine/tests/remote_relationship_removal.rs:37-...` — testuje trigger jako główny mechanizm domenowy.

**Opis:** SQL dobrze nadaje się do constraintów, FK i prostych invariantów, lecz tutaj implementuje pełny workflow z formatem wiadomości, polityką historii i cleanupem technicznym. Druga implementacja istnieje w runtime, więc zmiana wymaga synchronizacji dwóch state machine.

**Scenariusz:** Nowa tabela capability/outbox zostaje dodana, ale tylko jedna ścieżka removal ją czyści. Świeża instalacja i baza po innej sekwencji migracji mogą zachowywać się inaczej. Błąd triggera ujawnia się dopiero podczas INSERT wiadomości.

**Wpływ:** Wysokie ryzyko driftu, trudne testy jednostkowe, koszt migracji i nieprzewidywalne efekty uboczne.

**Przyczyna:** Próba zapewnienia atomowości przez przeniesienie procesu domenowego do triggerów zamiast użycia jawnego Unit of Work.

**Rekomendacja:** Pozostawić w SQL FK, unique/check, monotonic guards i ewentualnie minimalne ochrony tombstone. Przenieść workflow relacji do typowanego repository/process manager uruchamianego w jednej transakcji. Dodać jedną funkcję `apply_relationship_transition(tx, command)` używaną dla local/remote. Stare triggery usuwać etapami po migracji i testach równoważności.

**Test regresyjny:** Tabela testów przejść local/remote/replay/re-pair/crash uruchamiana dla starej i nowej implementacji; porównanie końcowego zestawu rekordów. Migration test z każdej wersji.

**Ryzyko zmiany:** Usunięcie triggerów za wcześnie może otworzyć race między starym i nowym klientem. Najpierw dual-write verification bez podwójnych side effects, potem drop w osobnej migracji.

---

## TC-017 — Ważność invite/endpoint i kolejność relationship removal zależą od nieskorygowanego wall clock

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** Czas / system rozproszony

**Dowód:**
- `common/torchat-core/src/lib.rs:123-128` — invite jest odrzucany, gdy `expires_at < SystemTime::now()` bez tolerancji.
- `common/torchat-core/src/peer_protocol.rs:126-140` — endpoint expiry jest porównywany do lokalnego `now`.
- `common/torchat-client-engine/sql/migrations/014_runtime_integrity.sql:215-267` — świeżość removal opiera się na zdalnym ISO timestampie porównanym z lokalnym relationship boundary.
- `common/torchat-client-runtime/src/clock.rs` istnieje, ale core/engine helpery nadal bezpośrednio czytają `SystemTime`.

**Opis:** Retry deadlines używają mieszanki `Instant` i unix timestamps. Dla ważności protokołu i relacji nie ma modelu maksymalnego clock skew ani logicznej epoki relacji.

**Scenariusz:** Telefon ma zegar 10 minut do przodu: świeży 15-minutowy invite może szybko wygasnąć, endpoint zostać uznany za stary. Telefon z zegarem do tyłu może przyjąć dłużej ważny artefakt. Opóźniony removal z błędnym future timestampem może pokonać późniejszą relację.

**Wpływ:** Niedeterministyczne pairing/P2P, replay guards zależne od jakości zegara i możliwość błędnego usunięcia nowej relacji.

**Przyczyna:** Wall clock pełni jednocześnie rolę UX expiry, kolejności domenowej i scheduler deadline.

**Rekomendacja:** Wstrzyknąć `Clock` do core/engine, użyć monotonic deadlines wewnątrz procesu, a w wire expiry dopuścić jawny bounded skew. Kolejność relacji oprzeć na losowym/monotonicznym `relationshipEpoch` ustanowionym przy pairing, nie na timestampie nadawcy.

**Test regresyjny:** Macierz ±1 min, ±10 min, ±24 h dla invite, endpointu i removal; opóźniony removal z poprzedniej epoki zawsze ignorowany niezależnie od czasu.

**Ryzyko zmiany:** Tolerancja skew wydłuża okno replay. Musi być mała i połączona z jednorazowym invite ID, sekwencją endpointu i epoch relacji.

---

## TC-018 — CI i supply chain nie są przypięte ani kompletne dla release security

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** M  
**Kategoria:** CI/CD / supply chain

**Dowód:**
- `.github/workflows/release-0-1-validation.yml:23-29,63,75-79,95-103,121-129,157-171` — `ubuntu-latest`, `windows-latest`, actions `@v4/@v2`, Rust `stable`, Flutter `stable` są ruchome.
- `.github/workflows/release-0-1-validation.yml:45-52` — fmt/check/test/clippy, ale brak `cargo audit`, `cargo deny`, SBOM, provenance i license policy.
- `Cargo.lock` — równolegle kilka generacji `rand`, `rand_core`, `digest`, `sha2`, `chacha20` i kilka backendów crypto przez OpenMLS/HPKE/ring/rustls.

**Opis:** CI ma dobre podstawy jakości, ABI i real-Tor gate, ale build release nie jest reprodukowalny w czasie i nie weryfikuje znanych podatności/licencji/provenance.

**Scenariusz:** Mutable action/toolchain zmienia się bez zmiany repo; build zaczyna używać innego kompilatora lub action. Podatność w zależności crypto pozostaje niewykryta. Nie ma SBOM do odpowiedzi incydentowej.

**Wpływ:** Ryzyko supply-chain i trudność odtworzenia APK/binary. Duplikaty bibliotek nie są same w sobie błędem, ale zwiększają powierzchnię aktualizacji.

**Przyczyna:** Workflow skupia się na funkcjonalnej walidacji 0.1, nie na release provenance.

**Rekomendacja:** Pinować actions po commit SHA, Rust przez `rust-toolchain.toml`, Flutter/Java/OS image w kontrolowanym zakresie. Dodać `cargo audit`/OSV, `cargo deny` dla licencji/źródeł/duplikatów krytycznych, SBOM CycloneDX/SPDX, artifact attestation/provenance i skan obrazu. Ustalić policy update Tor/OpenMLS.

**Test regresyjny:** CI ma fail na znanej testowej advisory, niezatwierdzonej licencji i nieprzypiętej action. Dwa buildy z tego samego commita powinny mieć udokumentowany poziom reprodukowalności.

**Ryzyko zmiany:** Ścisłe deny duplikatów może być nierealne dla OpenMLS stack. Zacząć od raportowania i allowlisty z właścicielem/terminem.

---

## TC-019 — Brakuje automatycznych testów crash/fuzz/property dla kluczowych gwarancji, a real-Tor nie jest bramką PR

**Severity:** MEDIUM  
**Priority:** P1  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Testy

**Dowód:**
- `.github/workflows/release-0-1-validation.yml:54-66` — test dwóch silników przez Tor jest pomijany dla pull requestów i sprawdza ping/pong.
- `common/torchat-client-engine/tests/delivery_resilience.rs:64-...` — istnieją wartościowe testy restart/dedupe, ale zakres jest wąski.
- `common/torchat-client-engine/tests/pairing_recovery.rs`, `pending_welcome_retention.rs`, `remote_relationship_removal.rs` — pokrywają pojedyncze recovery paths.
- Brak targetów/dependencies `cargo-fuzz`, `proptest`, `quickcheck`, `loom` w dostarczonym materiale.

**Opis:** Testy pokazują świadomą pracę nad resilience, ale nie obejmują granic commitu i kolejności wszystkich durable workflows. Najgroźniejszy TC-002 powstaje właśnie między udanym commitem a efektem receipt.

**Scenariusz:** Refaktor przechodzi unit tests, lecz zmienia kolejność ACK/outbox/MLS albo zachowanie po kill -9. Niepoprawna ramka peer ujawnia panic/duży allocation dopiero w produkcji.

**Wpływ:** Regresje utraty wiadomości/desynchronizacji mogą przejść CI; bezpieczeństwo parserów zależy od ręcznych przykładów.

**Przyczyna:** Brak wspólnego fault-injection harness dwóch peerów i systematycznego modelu state-machine testing.

**Rekomendacja:** Zbudować deterministyczny two-peer harness z fake clock/RNG/transport i punktami crash injection przed/po każdym commicie/efekcie. Dodać property tests state transitions, fuzzing wszystkich kodeków/ramek i nightly real-Tor E2E z wiadomością, pairingiem, fallbackiem i restartem. Na PR uruchamiać krótszy Tor smoke lub hermetyczny symulator.

**Test regresyjny:** Macierz w sekcji „Braki testowe” raportu jest minimalnym acceptance planem P0/P1.

**Ryzyko zmiany:** Real Tor jest wolny/flaky. Rozdzielić deterministyczne testy protokołu od mniejszej liczby real-network gates; nie maskować błędów automatycznym retry całego testu.

---

## TC-020 — Relay fallback jest wyłącznie live forwarding, nie trwałym store-and-forward — kontrakt produktu musi to mówić wprost

**Severity:** INFO  
**Priority:** P2  
**Confidence:** high  
**Effort:** S  
**Kategoria:** Semantyka dostarczenia

**Dowód:**
- `server/torchat-server/src/main.rs:1362-1443` — relay szuka odbiorcy w mapie aktywnych połączeń, forwarduje do bounded queue albo zwraca `RecipientOffline`.
- `server/torchat-server/sql/schema_migrations.sql` i zapytania — brak tabeli przechowującej application envelopes.
- `common/torchat-client-runtime/src/message_rules.rs:24-45,106-117` — `FORWARDED` daje `SENT`, a `RECIPIENT_OFFLINE` wraca do `QUEUED`.

**Opis:** Implementacja jest spójna i prywatnościowo korzystna: serwer nie trzyma ciphertextów. Trwałość znajduje się u nadawcy, który retry. Problem powstanie tylko wtedy, gdy UI/dokumentacja obiecuje „relay przechowa wiadomość dla offline recipienta”.

**Scenariusz:** Nadawca wybiera relay fallback, odbiorca jest offline. Relay zwraca offline, wiadomość pozostaje queued u nadawcy i dojdzie dopiero, gdy nadawca ponownie będzie online jednocześnie z drogą dostarczenia.

**Wpływ:** Brak utraty przy działającym outboxie, ale inne oczekiwania dostępności niż klasyczny komunikator store-and-forward.

**Przyczyna:** Świadoma architektura live-only; brak jednoznacznej nazwy/UX.

**Rekomendacja:** Nazwać tryb `live relay fallback`, opisać wymaganie aktywności nadawcy i nie przedstawiać `FORWARDED` jako dostarczenia. Jeśli wymagany jest offline relay, potrzebny jest osobny threat model retencji/metadanych, TTL i szyfrowany durable queue — nie dodawać tego przypadkowo.

**Test regresyjny:** Odbiorca offline: stan pozostaje queued po outcome; restart nadawcy zachowuje outbox; po równoczesnej dostępności dochodzi dokładnie raz.

**Ryzyko zmiany:** Brak zmiany kodu, o ile produkt akceptuje semantics. Zmiana na store-and-forward jest dużą zmianą prywatności i serwera.

---

## TC-021 — Mojibake jest widoczne w agregacie, ale nie można rozstrzygnąć, czy pochodzi z repozytorium czy eksportera

**Severity:** LOW  
**Priority:** P2  
**Confidence:** low  
**Effort:** S  
**Kategoria:** Jakość / encoding

**Dowód:**
- `common/internal-runtime-fixtures.json` i liczne literały w agregacie zawierają sekwencje typu `Po┼é─àczono`.
- `.github/workflows/release-0-1-validation.yml:39-41` uruchamia `scripts/internal/check-text-encoding.ps1`.
- Nagłówek CODECAT zgłasza `WARNINGS: 0`, lecz sam agregat przeszedł przez warstwę eksportu.

**Opis:** Znaki są niewątpliwie uszkodzone w materiale audytowym, ale nie ma dowodu, że identyczne bajty znajdują się w Git. Mogło dojść do wielokrotnej konwersji UTF-8/CP podczas agregacji.

**Scenariusz:** Jeśli błąd jest w repo, użytkownik widzi uszkodzone notyfikacje i komunikaty. Jeśli tylko w eksporcie, masowa automatyczna „naprawa” repo uszkodzi poprawne teksty.

**Wpływ:** Potencjalny błąd UX i ryzyko błędnej naprawy bez weryfikacji.

**Przyczyna:** Nieustalone kodowanie źródła/eksportu.

**Rekomendacja:** Na rzeczywistym checkout uruchomić istniejący checker, `git grep` po charakterystycznych sekwencjach i sprawdzić bajty `xxd/file`. Naprawiać wyłącznie pliki potwierdzone w Git; dodać golden test polskich tekstów w UTF-8.

**Test regresyjny:** Checker na czystym checkout plus test JSON/Dart/Rust round-trip `Zażółć gęślą jaźń`. Eksport CODECAT powinien zachować ten sam SHA/bajty.

**Ryzyko zmiany:** Nie wykonywać globalnego transcodingu na podstawie tego agregatu.

---

## TC-022 — Największe moduły nadal łączą kilka odpowiedzialności i tworzą wysokie ryzyko zmian przekrojowych

**Severity:** MEDIUM  
**Priority:** P2  
**Confidence:** high  
**Effort:** L  
**Kategoria:** Architektura / modularność

**Dowód:**
- `common/torchat-client-runtime/src/runtime.rs` — 3068 linii.
- `server/torchat-server/src/main.rs` — 1821 linii.
- `common/torchat-client-engine/src/storage/runtime_storage.rs` — 1609 linii.
- `common/torchat-client-engine/src/actor/mod.rs` — 1320 linii mimo wydzielonych submodułów.
- `scripts/internal/check-source-size.ps1` pokazuje, że problem jest już monitorowany ratchetem.

**Opis:** Repo ma sensowne crate boundaries i rozpoczęty podział actor, ale duże pliki nadal zawierają modele przejść, repozytoria, workflow, mappingi i efekty. Nie jest to argument za rewrite; jest to granica kosztu kolejnych feature’ów.

**Scenariusz:** Zmiana pairingu dotyka runtime.rs, actor, SQL, relay main i UI; code review nie widzi pełnej state machine. Nowa kolejka lub stan jest mapowany w kilku miejscach i łatwo pominąć cleanup/recovery.

**Wpływ:** Wolniejsze review, większe ryzyko regresji i trudniejsze testy jednostkowe.

**Przyczyna:** Szybka ewolucja PoC i koncentracja logiki w centralnych orchestratorach.

**Rekomendacja:** Podział według durable workflow, nie według warstw technicznych: `message_delivery`, `pairing_process`, `relationship_process`, `endpoint_capability_process`; osobno repositories i typed transactions. Server: auth/bootstrap, pairing handlers, session registry/router, storage, cleanup. Zachować jeden actor jako serializer, ale delegować do małych command handlerów.

**Test regresyjny:** Każdy wydzielony moduł ma contract/state transition tests; source-size ratchet obniżany etapami, bez samego przesuwania kodu do innych god files.

**Ryzyko zmiany:** Nadmierna liczba crate’ów zwiększy build i API surface. Najpierw moduły wewnątrz obecnych crate’ów; biblioteki tylko dla stabilnych granic opisanych w raporcie.

---

# 9. Niespójności między warstwami

| Funkcja | UI | Kontrakt | Runtime | Engine | Storage | Transport | Problem |
|---|---|---|---|---|---|---|---|
| Read receipts | wywołuje po focus i ignoruje błąd | publiczne + READ | ma reguły read | zwraca Unsupported | ma read timestamps | brak durable outbound | funkcja pozorna. |
| Relationship removal | tworzy magic body + drugi command | typed command istnieje, typed app payload istnieje | lokalny transition | usuwa mapy po command | trigger interpretuje body i kasuje | normalna wiadomość/relay | trzy konkurencyjne implementacje. |
| Command idempotency | request ID użyty jako command ID | pole istnieje | processed commands | obsługuje hash payload | trwała tabela | n/d | desktop gubi ID; retry ID niestabilne. |
| Startup readiness | hard gate | oddzielne pola readiness | statusy komponentów | raportuje oddzielnie | local data gotowe | relay/P2P niezależne | UI scala wszystko do jednego gate. |
| Relay delivery | UI może pokazywać send | FORWARDED/DELIVERED rozdzielone | poprawne state rules | poprawne outcome mapping | sender outbox | live-only | wymaga jasnego UX, nie store-and-forward. |
| Capability exchange | status API | publiczne rotate/revoke | models | durable offer+ACK | capability tables/outbox | bootstrap przez relay, auth P2P | zasadniczo spójne; brak dead-letter. |
| Typing/presence/focus | publiczne | publiczne | transient events | peer control, nie MLS | tylko last_seen | best effort P2P | spójne, ale UI musi pokazać transient nature. |
| Pairing inbox/control | publiczne | publiczne | merge/transition | router przekazuje do blocking worker | durable local state | HTTP relay | nie jest faktycznie Unsupported na public path; architektura rozproszona. |

## 9.1 Macierz publicznego API

| Operacja | UI/host | Kontrakt | Engine | Runtime/storage | Test | Spójna |
|---|---|---|---|---|---|---|
| bootstrap | tak | tak | tak | tak | częściowy | tak |
| connect | tak | tak | tak | tak | częściowy | tak |
| getIdentity/getProfile | tak | tak | tak | tak | fixture/contract | tak |
| getStartupReadiness | tak | tak | tak | projection | startup tests | częściowo — UI nadmiernie gate’uje |
| getApplicationSnapshot | tak | tak | tak | jedna transakcja | snapshot tests | tak |
| pairingInbox/pairingOutbox | tak | tak | control worker/runtime | tak | pairing tests | tak, lecz saga rozproszona |
| listContacts/listConversations/listMessages | tak | tak | tak | tak | UI/domain | tak |
| get/retry/rotatePeerEndpoint | tak | tak | tak | endpoint tables | częściowy | tak |
| get/rotate/revokeContactEndpointCapability | tak | tak | tak | capability tables/outbox | ograniczony | częściowo — brak dead-letter |
| setNickname | tak | tak | relay control worker | runtime commit | contract | tak |
| refresh/submitPairingCode | tak | tak | relay control worker | pairing rows | pairing tests | tak |
| accept/reject/archive/cancelPairing | tak | tak | tak/control worker | state rules | częściowy | częściowo — brak pełnych race tests |
| verifyContact/updateContactSettings | tak | tak | tak | tak | UI/domain | tak |
| removeRelationship | tak | tak | tak | tak + SQL trigger | remote removal test | nie — TC-001 |
| start/open/closeConversation | tak | tak | tak | tak | UI | tak |
| sendMessage/retryMessage | tak | tak | tak | durable encryption/outbox | resilience | tak |
| deleteMessageLocal | tak | tak | tak | tak | UI | tak |
| setTyping/setConversationFocus/setPresence | tak | tak | peer control | transient state | presence/UI | tak jako best effort |
| sendReadReceipts | tak | tak | Unsupported | read model istnieje | brak E2E | nie — TC-008 |
| platformFact | native host | tak | tak | actor state | platform tests | tak |
| shutdown | tak | tak | tak | cancellation | FFI tests | tak |

---

# 10. Proponowana architektura docelowa

## 10.1 Zasada ewolucji

Nie przepisywać aplikacji. Zachować obecne crate’y i actor jako serializator, lecz zmienić zawartość actor z dużej logiki workflow na dispatcher małych command handlerów. Każdy workflow, który przeżywa restart, powinien mieć jeden rekord procesu i jeden właściciel.

```text
UI
  -> generated typed Engine API
    -> CommandRouter
      -> Query handlers (read-only projection)
      -> Transactional command handlers
          -> UnitOfWork / repositories
          -> append durable ProcessRecord + OutboxEffect
      -> ProcessSupervisor
          -> MessageDeliveryProcess
          -> PairingProcess
          -> RelationshipProcess
          -> CapabilityExchangeProcess
          -> EndpointRotationProcess
      -> EffectDispatcher
          -> PeerPort
          -> RelayControlPort
          -> RelayDataPort
          -> PlatformPort
      -> ProjectionPublisher
```

## 10.2 Granice transakcyjne

1. Command handler otwiera Unit of Work.
2. Waliduje typed state transition.
3. Aktualizuje dane domenowe, kryptograficzny snapshot i durable process/outbox w jednym commicie.
4. Dopiero po commicie EffectDispatcher próbuje efektu.
5. Wynik efektu jest osobnym idempotentnym commandem procesu.
6. ACK transportowy nie może zmienić znaczenia już zatwierdzonego commitu aplikacyjnego.

## 10.3 Transport policy

Zachować `PEER_ONLY`, `PEER_WITH_RELAY_FALLBACK`, `RELAY_ONLY`, ale strategy ma zwracać typed decyzję i wymaganą capability readiness. Relay control readiness nie powinien być globalnym warunkiem P2P. Live relay fallback należy nazwać w modelu, aby nie sugerował store-and-forward.

## 10.4 Readiness

Wprowadzić capabilities: `LocalDataReadable`, `LocalMutationsAvailable`, `TorSocksReady`, `OnionPublished`, `RelayControlReady`, `RelayDataReady`, `PeerReachable(contact)`. Shell otwierać przy pierwszych dwóch; operacje używają własnych preconditions.

## 10.5 Contract generation

Generator powinien wytwarzać: typed command structs, response decoders, enumy błędów, capability manifest i adaptery Kotlin/Dart. Host ma przekazywać `operationId` bez interpretacji. Ręczne switche pozostawić tylko dla platform actions.

## 10.6 Migracja etapami

1. **Etap 0:** naprawy P0 bez zmiany publicznego UX: commit-aware receive result, pairing secret, desktop submit_envelope, bezpieczny remote removal.
2. **Etap 1:** stabilny operation ID i wspólny RetryPolicy; readiness capabilities.
3. **Etap 2:** `relationship_process` i `pairing_process` jako moduły wewnątrz engine; usunięcie magic body.
4. **Etap 3:** przeniesienie logiki z triggerów do Unit of Work; triggery pozostają guardami.
5. **Etap 4:** split server i opcjonalny distributed session registry, tylko jeśli wymagany multi-instance.

---

# 11. Kandydaci do refaktoryzacji

| Moduł | Obecny problem | Proponowany podział | Wzorzec | Korzyść | Koszt |
|---|---|---|---|---|---|
| runtime.rs | 3068 linii, wiele agregatów/workflow | message, pairing, contact, projection services | command handlers + domain services | widoczne przejścia i testy | L |
| actor/mod.rs + submoduły | actor jest dispatcherem i częścią procesów | router, supervisor, effect dispatcher | actor + process manager | jedna granica commitu | L |
| runtime_storage.rs | repozytoria i workflow w jednym pliku | repositories per aggregate + UnitOfWork | repository/UoW | mniej duplikacji SQL/domain | L |
| migration 014 | pełny workflow w triggerach | constraints/guards + Rust transition | explicit state machine | testowalność i wersjonowanie | L |
| server/main.rs | routing/auth/pairing/storage w 1821 liniach | auth, pairing, sessions, router, storage, cleanup | ports/adapters | multi-instance i abuse controls | L |
| Flutter controllers | readiness i relationship wire logic | capability gate + typed commands | anti-corruption layer | UI bez protokołu | M |
| desktop identity/stdio | plaintext secret i utrata command ID | secure store + thin host adapter | platform adapter | security i kontrakt | M |
| retry helpers | kilka liczbowych backoffów | shared policy/error taxonomy | strategy | jitter/dead-letter | M |

---

# 12. Kandydaci do osobnych bibliotek

| Kandydat | Decyzja | Publiczne API | Zależności | Uzasadnienie |
|---|---|---|---|---|
| Modele/kodeki protokołu (`torchat-core`) | pozostawić | invite/application/peer/relay codecs | serde, crypto, OpenMLS | już ma stabilną wspólną granicę; nie rozdrabniać. |
| Tożsamość | pozostawić | Identity/sign/verify/fingerprint | ed25519 | używana wspólnie, ale zbyt związana z core, by tworzyć kolejny crate teraz. |
| Peer handshake | wydzielić później | client/server handshake state machine | core identity + peer frames | warto po dodaniu fuzz/property i ustabilizowaniu wersji. |
| Endpoint capabilities | wydzielić później | mint/rotate/revoke/proof | storage port + HMAC | obecnie workflow jeszcze się zmienia. |
| Retry policy | wydzielić | classify, next_delay, max_age | Clock + RNG | wiele kolejek i hostów, stabilny mały kontrakt. |
| Encrypted storage abstractions | pozostawić | RuntimeStorage/UoW | rusqlite/SQLCipher | współdzielony host nie potrzebuje osobnego package; zachować w engine. |
| Migracje | pozostawić | MigrationRunner | SQLite | muszą ewoluować z konkretnym schematem klienta. |
| Engine contract/gen | wydzielić | schema + generators + compatibility checker | serde_json | używane przez Rust/Dart/Kotlin; już naturalna granica. |
| FFI support | pozostawić | opaque handle/C ABI/json | engine | ma pojedynczego konsumenta; osobny crate już istnieje. |
| Diagnostyka/sanitizacja | wydzielić później | redact/pseudonymize/retention | logging ports | warto współdzielić klient/server po naprawie TC-011. |
| Platform facts | pozostawić | typed facts/actions | contract | wąski anti-corruption layer już działa. |
| Two-peer fault harness | wydzielić | scenario DSL, crash points, fake ports | engine/runtime/core | użycie przez wiele test suites i real-Tor adapter. |

---

# 13. Braki testowe

| Scenariusz | Test istnieje | Poziom | Brak | Proponowany test |
|---|---|---|---|---|
| Dwaj klienci przez rzeczywisty Tor | częściowo | skrypt integracyjny | ping/pong, nie pełna wiadomość/restart | pair + message + delivery + restart + endpoint rotation. |
| Restart nadawcy po zapisie przed wysłaniem | częściowo | DB integration | brak real engine crash point | fault injection po commit przed dispatch. |
| Restart odbiorcy po Persisted przed Delivered | częściowo | DB inbox restart | brak live peer ACK race | kill receiver po Persisted; sender retry; exactly once. |
| Błąd receipt po commit wiadomości | nie | integration | TC-002 | fail storage/transport w flush receipt. |
| Duplikat samego ciphertextu | tak częściowo | DB integration | pełny P2P/relay | send duplicate przez oba transporty. |
| Ten sam message ID z innym ciphertextem | tak DB | integration | wire path | assert reject/quarantine bez drugiej wiadomości. |
| Replay starego endpointu | unit częściowo | core/actor | sesja + restart | old sequence po new endpoint i po restart. |
| Replay starego capability | niepełny | storage/unit | revoked secret handshake | old proof nie autoryzuje. |
| Niepoprawny capability proof | ograniczony | peer unit | real inbound | handshake reject, bounded response/time. |
| Stale MLS generation | nie | crypto integration | recovery policy | out-of-order/drop/rollback matrix. |
| Utrata ACK | częściowo | delivery resilience | P2P Persisted/Delivered osobno | drop each ACK and restart. |
| Relay przyjmuje, odbiorca nie stosuje | częściowo | message rules | live E2E | FORWARDED remains SENT; retry/receipt resolution. |
| Fallback P2P→relay | niepełny | actor | real Tor | peer unavailable, same ciphertext via relay. |
| PEER_ONLY bez peera | niepełny | runtime | UX+retry | queued/degraded, no relay leakage. |
| Wielokrotny accept pairing | częściowo | pairing recovery | concurrent hosts | same operation ID + distinct IDs. |
| Welcome wielokrotnie | częściowo | retention | two clients | one contact/group, app ACK idempotent. |
| Crash podczas każdej migracji | nie | migration | partial DDL/transaction | failpoint per migration statement. |
| Re-pair po removal + opóźniony removal | tak częściowo | SQL integration | typed process | relationship epoch property test. |
| Clock skew | nie | unit/property | invite/endpoint/removal | fake clock matrix. |
| Niepoprawne UTF-8 / oversize | częściowo | unit | fuzz all parsers | cargo-fuzz corpus + max allocation. |
| Fuzz kodeków i peer frames | nie | fuzz | całość | RelayPayload, ApplicationPayload, PeerFrame, snapshot. |
| Property state transitions | nie | property | message/pairing/process | proptest legal/illegal transitions. |
| Android process death/background restriction | contract częściowo | Flutter/Kotlin | real lifecycle | instrumented service restart + queued message. |
| Desktop vault/rekey migration | nie | platform integration | TC-003 | Windows/Linux/macOS secure-store tests. |
| Dwie instancje relay | nie | server integration | TC-012 | cross-instance challenge/ws routing. |

## 13.1 Priorytet testów

**P0:** TC-001 remote/local removal, TC-002 post-commit receipt, desktop secret migration, host compose start, cross-host operation ID.  
**P1:** crash/ACK matrix, fallback, repeated Welcome, stale endpoint/capability, clock skew, fuzz pre-auth frames, state properties.  
**P2:** multi-instance relay, upgrade golden MLS snapshots, long-run queue/retention/battery tests.

---

# 14. Wydajność i obserwowalność

## 14.1 Wydajność

- Najistotniejsze znalezisko to `Vec::remove(0)` w relay-control; peer queue poprawnie używa `VecDeque`.
- Główne kanały mają capacity; wyjątek to relay bootstrap/control outcomes.
- Actor wykonuje wiele synchronicznych operacji rusqlite na swoim wątku. Są lokalne i transakcyjne, lecz przy rosnącej bazie/prune mogą wydłużać latency. Nie znaleziono dowodu, że obecnie blokują na sekundy; monitorować p95 transaction time przed wprowadzaniem `spawn_blocking` wszędzie.
- Projection snapshot w jednej transakcji jest lepszy niż N równoległych zapytań. `listMessages` zwraca pełną listę; istnieją modele paging, lecz należy upewnić się, że UI używa limitów dla długich rozmów.
- Relay poll 100 ms w foreground może być kosztowny, ale adaptive intervals istnieją dla battery/idle/background. Pomiar na Androidzie powinien poprzedzić optymalizację.
- MLS snapshots mogą rosnąć; brak metryki rozmiaru per conversation i czasu restore.

## 14.2 Obserwowalność

Po stronie klienta istnieją correlation/message IDs, retry attempts, connection generations, pseudonymous target IDs i sanitization test ZIP. Po stronie serwera tracing jest strukturalny, ale za bardzo identyfikujący. Dodać metryki bez danych osobowych: queue depth/age, retry/dead-letter, handshake rejection reason class, relay sessions, forward latency, P2P ACK latency, MLS restore/decrypt failures, migration duration. Diagnostyka użytkownika powinna pokazywać komponent, nie surowy onion/installation ID.

---

# 15. CI/CD, build i supply chain

Obecny workflow jest dobrym quality gate dla PoC: fmt/check/test/clippy, Flutter analyze/test, Android/Windows build, ABI check, contract/architecture/SQL/encoding/source-size checks, signed APK manual gate i real-Tor mainline. Do produkcji brakuje: SHA-pinned actions, pinned toolchains, vulnerability/license scan, SBOM, provenance/attestation, container scan, release signature policy, reproducibility statement i test host compose. `Cargo.lock` pokazuje kilka generacji bibliotek crypto; należy audytować ich pochodzenie i aktualizacje, a nie automatycznie usuwać duplikaty wymuszone przez OpenMLS.

---

# 16. Plan działań

## P0 — przed kolejnym wydaniem

| Zadanie | Zależności | Koszt | Ryzyko | Kryterium ukończenia |
|---|---|---|---|---|
| Zastąpić magic relationship removal typowanym durable workflow | engine contract, runtime, migration, Flutter | L | kompatybilność starych klientów | zdalny body nie kasuje danych; crash/replay/re-pair tests przechodzą. |
| Rozdzielić inbound commit od flush receipt | actor/peer ACK | M | zmiana outcome sendera | po commit zawsze Delivered; receipt retry niezależny. |
| Naprawić desktop secret storage i niezależny DB key | platform vaults, rekey | L | utrata dostępu przy migracji | atomowa migracja i brak plaintext sekretu. |
| Dodać pairing secret do host/staging | server config, Docker secret, bootstrap | S | rotacja istniejącego sekretu | fresh host compose health i config test. |
| Zachować stabilny operation ID end-to-end | desktop stdio, Android host, Flutter repository | M | stare hosty | lost-response retry wykonuje jeden efekt na wszystkich platformach. |
| Dodać P0 regression/fault tests | two-peer harness | M | czas CI | każdy powyższy finding ma automatyczny test. |

## P1 — najbliższy sprint

| Rozdzielić local readiness od transport readiness | Flutter model/controller | M | zmiana nawigacji | historia działa offline; per-operation gates. |
| Wspólny RetryPolicy + jitter + error taxonomy | Clock/RNG, wszystkie queue repositories | M | zmiana deadline’ów | bounded retry, dead-letter, diagnostyka. |
| Uzgodnić read receipts: usunąć z 0.1 albo durable implementation | contract/product decision | M/L | kompatybilność | contract/UI/engine spójne. |
| Sanityzować logi relay i ustalić retencję | tracing layer | S | mniejsza diagnostyka | test nie znajduje raw graph metadata. |
| Wymusić single-instance relay i dodać abuse budgets | deployment/router | M | false positives Tor | bounded load; jawny deployment invariant. |
| Clock adapter + relationship epoch design | core/runtime/storage | M | wire migration | skew tests i stale removal niezależny od czasu. |
| Uruchomić fuzz/property/crash suite | test harness | L | flakiness | PR deterministic suite + nightly real Tor. |

## P2 — kolejne 2–4 sprinty

| Wydzielić process manager pairingu i capability exchange | P0 stable semantics | L | duży refaktor | jedna tabela/stany procesu, recovery tests. |
| Przenieść workflow z SQL triggerów do UnitOfWork | relationship process | L | migration drift | triggery tylko invariants; equivalence tests. |
| Wersjonować MLS snapshot i dodać golden upgrade tests | OpenMLS policy | L | crypto migration | poprzedni release snapshot jest czytelny. |
| Retencja processed_commands i queue maintenance | RetryPolicy | S/M | zbyt krótki horizon | bounded DB growth. |
| Rozbić server/main.rs | server tests | L | routing regressions | moduły auth/pairing/sessions/router/storage. |
| Supply-chain hardening | CI ownership | M | build maintenance | pinned actions, SBOM, audit/deny, provenance. |

## P3 — późniejsze usprawnienia

| Distributed relay registry/pub-sub, jeśli wymagany multi-instance | jasne SLA/skala | XL | metadata/złożoność | cross-instance tests i rolling deploy. |
| Padding/batching metadata | threat model i pomiary | L/XL | latency/bateria | udokumentowany privacy benefit. |
| Wyciągnięcie peer handshake library | stabilny protocol v1 + fuzz | M | API surface | niezależne testy client/server. |
| Dalsza redukcja god modules | process managers gotowe | L | over-engineering | source ratchet i prostsze review. |
| Zaawansowane backup/device migration | anti-rollback design | XL | security tradeoffs | jawny bezpieczny recovery protocol. |

---

# 17. Pytania otwarte

- Jaki jest formalny model zagrożeń: czy relay/operator jest aktywnie złośliwy, czy tylko honest-but-curious? honest-but cirious
- Czy produkt 0.1 obiecuje możliwość czytania historii całkowicie offline? historia jest tylko na urzadzeniu nie ma jej nigdzie indziej, wiec powinien moc czytac cala, bo nalezy do niego
- Czy relay ma pozostać live-only, czy oczekiwane jest store-and-forward dla offline recipienta? zostaje tak jak jest
- Jaka jest wymagana maksymalna liczba jednoczesnych użytkowników i czy multi-instance relay jest celem 0.1? relay jest tylko do parowania, kiedys usuniemy te komunikacje, nie ma limitu uzytkownikow, 
- Czy jedna tożsamość może mieć wiele urządzeń/sesji, czy „jedno aktywne połączenie” jest kontraktem produktu? jedno urzadzenie jeden user
- Jaka jest lokalna polityka retencji po zakończeniu relacji i kto może ją zmienić? co to znaczy ?
- Czy backup/restore bazy i migracja urządzenia są wspierane? Jeśli tak, jak rozwiązać anti-rollback MLS? bedzie moze w przyszlosci
- Jaki maksymalny clock skew ma być tolerowany? nie wiem co to znaczy, jesli zegar to minimalny kazdy powinien miec sync i strefe czasiowa
- Jak długo relay i klient przechowują logi/diagnostykę i kto ma do nich dostęp? tydzien, przy starcie palikacji powinien byc modal wysylaj dane diagnostyczne i wysyla je na serwer spakowane, bo bledach
- Jak długo operation ID musi gwarantować idempotency przy urządzeniu offline? forever
- Jakie platformy są release targets 0.1: Android/Windows, również Linux/macOS?Android windows Linux
- Jaka jest polityka aktualizacji Tor, OpenMLS i protokołu wire między wersjami klienta? na razie o tym nie myslimy chcemy miec stabilne 0.1, bez legacy sciezek no dead code etc

---

# 18. Pokrycie audytu

| Obszar | Liczba plików dostarczonych | Przejrzane | Pominięte z dostarczonych | Powód |
|---|---:|---:|---:|---|
| Dokumentacja i konfiguracja repozytorium | 10 | 10 | 0 | — |
| Kod mobilny i integracje platformowe | 53 | 53 | 0 | — |
| Kod produkcyjny | 194 | 194 | 0 | — |
| Kod wygenerowany, lock i zasoby zależności | 16 | 16 | 0 | — |
| Kontrakty i modele protokołu | 3 | 3 | 0 | — |
| Migracje i zapytania SQL | 54 | 54 | 0 | — |
| Serwer / relay | 2 | 2 | 0 | — |
| Skrypty, CI/CD i infrastruktura | 40 | 40 | 0 | — |
| Testy | 51 | 51 | 0 | — |
| **Razem w agregacie** | **423** | **423** | **0** | — |
| **Elementy pominięte przez eksporter przed agregacją** | **81** | **0** | **81** | ścieżki nieudostępnione; rozkład powodów w sekcji 2.1 |

### Głębokość

- Ręcznie prześledzone end-to-end: startup, pairing, send, receive, P2P handshake, relay routing/control, relationship removal, restart queues, FFI/host lifecycle.
- Wszystkie migracje i SQL queries: zinwentaryzowane; schemat, constraints, indeksy, timestampy i triggery przeanalizowane statycznie.
- Wszystkie testy: sklasyfikowane i sprawdzone pod kątem scenariuszy, lecz nie uruchomione.
- Wszystkie pliki platform/CI/infra: przegląd statyczny; buildy nieuruchomione.
- Generated/lock: sprawdzone źródło generacji, manifest drift controls i dependency duplication; nie analizowano boilerplate linia po linii.

### Niewykonane działania dynamiczne

`cargo test/check/clippy/fmt`, `flutter test/analyze/build`, Kotlin/Gradle tests, PowerShell checks, Docker deployment, SQL migration execution, real Tor E2E, vulnerability database scan i fuzzing. Brak tych wyników jest powodem, dla którego raport nie może potwierdzić gotowości release nawet po statycznych poprawkach.

---

# 19. Konkluzja

TorChat ma wystarczająco dobre fundamenty, aby kontynuować bez rewrite. Najważniejsze decyzje techniczne — wspólny Rust engine, SQLCipher, trwałe ciphertexty/snapshoty, effectively-once receive, signed endpointy/capability handshake i oddzielenie relay `FORWARDED` od delivery — są warte zachowania. Obecne ryzyko nie wynika z samego użycia Tor lub OpenMLS, lecz z granic pomiędzy stanem domenowym, transakcją i efektem zewnętrznym.

Po zamknięciu P0 i pierwszej fali P1 baza może rozsądnie ewoluować do produktu. Bez tych zmian wydanie powinno pozostać oznaczone jako eksperymentalne, ponieważ realne scenariusze mogą prowadzić do utraty historii, fałszywego odrzucenia już zapisanej wiadomości, przejęcia sekretów desktopowych i powtarzalnych problemów wdrożeniowych.

## Artefakty towarzyszące

- `TorChat-audyt-file-inventory.csv` — 423 rekordy pokrycia plików.
- `TorChat-audyt-findings.csv` — machine-readable lista 22 findingów.
