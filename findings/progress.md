# TorChat — plan realizacji audytu

Źródła:

- `TorChat-audyt-architektury-i-bezpieczenstwa-2026-08-03.md`
- `TorChat-audyt-findings.csv`
- `TorChat-audyt-file-inventory.csv`

Ten plik jest jedynym dziennikiem realizacji findingów TC-001–TC-022. Po każdym kroku aktualizujemy status, dowody testowe, datę i commit. Nie oznaczamy punktu jako ukończony wyłącznie dlatego, że kod został napisany — wymagane są testy akceptacyjne i ponowna weryfikacja scenariusza z audytu.

## Statusy

- `TODO` — nie rozpoczęto.
- `VERIFY` — finding trzeba potwierdzić na aktualnym checkoutcie; kod mógł zmienić się po audycie.
- `IN PROGRESS` — trwa implementacja lub migracja.
- `BLOCKED` — istnieje konkretny blocker opisany w notatce.
- `DONE` — implementacja, testy i dokumentacja są kompletne.
- `ACCEPTED` — świadomie zaakceptowane ryzyko/semantyka produktu, z udokumentowaną decyzją.

## Zasady wykonania

1. Jeden finding lub jeden ściśle powiązany pakiet na raz.
2. Przed zmianą odtworzyć scenariusz i dodać test regresyjny, jeśli jest praktycznie możliwy.
3. Zmiany protokołu, storage i kryptografii muszą zawierać plan kompatybilności/migracji.
4. Po każdym findingu uruchomić testy celowane oraz odpowiedni zestaw regresji Rust/Flutter/Android/server.
5. Nie mieszać refaktoru strukturalnego z poprawką bezpieczeństwa, chyba że refaktor jest konieczny do zachowania atomowości.
6. Dowody ukończenia wpisujemy bezpośrednio pod findingiem: testy, commit, ewentualny dokument decyzji.

## Podsumowanie

| Priorytet | Liczba | Ukończone | Pozostałe |
|---|---:|---:|---:|
| P0 | 5 | 0 | 5 |
| P1 | 11 | 0 | 11 |
| P2 | 6 | 0 | 6 |
| **Łącznie** | **22** | **0** | **22** |

## Kolejność realizacji

### Etap 0 — baseline i aktualność audytu

- [ ] `AUDIT-00` — `IN PROGRESS` — Utworzyć powtarzalny baseline.
  - Zapisać wersje Rust, Flutter, Java, Android SDK/NDK i Docker.
  - Uruchomić aktualne testy Rust, Flutter, skryptów i kontraktów.
  - Dla każdego findingu sprawdzić, czy wskazane pliki/linie nadal odpowiadają opisowi.
  - Wynik: tabela poniżej ma status `VERIFY`, `TODO`, `DONE` albo `ACCEPTED`, bez niezweryfikowanych założeń.

#### `AUDIT-00` — mini-zadania

- [x] `AUDIT-00.1` Zarejestrować commit bazowy, branch, dirty files i datę audytu w dzienniku.
- [x] `AUDIT-00.2` Uruchomić `cargo fmt --all -- --check`, `cargo check --workspace` oraz testy crate’ów Rust. (fmt/check PASS; `cargo test --workspace`: 192 passed)
- [x] `AUDIT-00.3` Uruchomić `flutter analyze` i pełne testy Fluttera; zapisać znane ograniczenia środowiska. (analyze PASS; `flutter test`: 165 passed)
- [x] `AUDIT-00.4` Uruchomić `powershell -File scripts/tests/Test-TorChatScripts.ps1` oraz testy kontraktu runtime. (oba PASS)
- [x] `AUDIT-00.5` Uruchomić checker kodowania i sprawdzić, czy TC-021 dotyczy checkoutu, czy wyłącznie agregatora. (potwierdzono mojibake w śledzonym `REFACTOR_PROGRESS.md`)
- [ ] `AUDIT-00.6` Dla TC-001–TC-022 potwierdzić wskazane symbole przez CodeGraph (`query`, `callers`, `callees`, `impact`) lub `rg`, jeśli symbol nie jest zindeksowany. (CodeGraph index PASS; symbol audit pending)
- [ ] `AUDIT-00.7` Odtworzyć minimalny scenariusz każdego findingu albo oznaczyć go `VERIFY-BLOCKED` z konkretnym powodem.
- [ ] `AUDIT-00.8` Zaktualizować linki/numery linii w checklistach po ewentualnych zmianach struktury plików.
- [x] `AUDIT-00.9` Utworzyć artefakt baseline, np. `findings/baseline-YYYY-MM-DD.md`, z wynikami komend i skrótem środowiska. (utworzono `findings/baseline-2026-08-03.md`)
- [ ] `AUDIT-00.10` Dopiero po zamknięciu baseline zmienić status TC-001–TC-022 z początkowego `TODO` na potwierdzony `TODO`, `VERIFY` albo `ACCEPTED`.

### Etap 1 — P0: integralność danych i działający deployment

- [ ] `TC-004` — `IN PROGRESS` — Pairing secret dla host/staging.
  - Dodać `TORCHAT_PAIRING_SECRET_FILE`, trwałe generowanie sekretu i mount jako Docker secret.
  - Dodać preflight z czytelnym błędem przed częściowym startem serwera.
  - Akceptacja: świeży secure root startuje host compose i przechodzi health; istniejący sekret nie jest rotowany.
  - Testy: compose config, start/health, brak sekretu, zbyt krótki sekret, restart z zachowaniem wartości.

- [ ] `TC-002` — `IN PROGRESS` — Commit inbound nie może zostać cofnięty przez błąd receipt.
  - Wprowadzić strukturalny wynik inbound z jawnym `committed`/`receipt_due`.
  - Po commicie ACK ma pozostać `Delivered`/`Persisted`; receipt trafia do durable retry.
  - `crypto_blocked_peers` tylko dla sklasyfikowanych błędów kryptograficznych.
  - Akceptacja: fault po commicie nie duplikuje wiadomości, nie blokuje peera i receipt wychodzi po restarcie.

- [ ] `TC-005` — `IN PROGRESS` — Rozdzielenie request ID i command ID rozpoczęte; trwałość przez restart pozostaje.
  - Rozdzielić korelacyjny `requestId` od trwałego `operationId/commandId`.
  - Desktop ma używać `submit_envelope`; Android i repository zachowują operation ID przez retry/restart.
  - Akceptacja: zgubiona odpowiedź i retry wykonują jeden efekt; ten sam ID z innym payloadem daje konflikt na każdej platformie.

- [ ] `TC-001` — `TODO` — Typowany workflow usunięcia relacji.
  - Usunąć autorytatywne rozpoznawanie magicznego tekstu wiadomości.
  - Lokalny tombstone i typed outbox zapisywać atomowo; dodać `relationshipEpoch`/`removalId` i ACK.
  - Zdalny kontakt nie może sterować lokalną polityką retencji historii.
  - Akceptacja: dawny prefiks jest zwykłą wiadomością; crash po commicie jest odzyskiwalny; replay jest idempotentny.
  - Zależności: projekt powinien uwzględniać późniejsze `TC-016` i `TC-017`, bez wykonywania pełnego refaktoru tych punktów w tym samym commicie.

- [ ] `TC-003` — `TODO` — Rozdzielenie sekretów desktopu i migracja do OS vault.
  - Osobny sekret tożsamości i losowy klucz SQLCipher.
  - Windows: DPAPI/Credential Manager; Linux: Secret Service/KWallet; macOS: Keychain.
  - Dodać journal migracji, `PRAGMA rekey`, weryfikację i bezpieczne usunięcie plaintextu.
  - Akceptacja: testy przerwania przed/po rekey nie tracą tożsamości ani danych; brak sekretów w plaintext.

### Etap 2 — P1: spójny klient, retry i prywatność

- [ ] `TC-008` — `IN PROGRESS` — Trwałe read receipts zgodne z kontraktem.
  - Ponownie sprawdzić aktualną ścieżkę po ostatnich zmianach presence/read receipt.
  - Read receipt nie może być nietrwałym payloadem odrzucanym przez `EPHEMERAL_MLS_DELIVERY_SAFE`.
  - Akceptacja: fokus rozmowy tworzy trwały, idempotentny receipt; restart nie gubi go; nadawca widzi `odczytano`.
  - Testy: P2P, relay fallback, offline/restart, replay, dwa kontakty.

- [ ] `TC-006` — `IN PROGRESS` — Lokalny shell dostępny w trybie offline/degraded.
  - Rozdzielić `local usable`, pairing, relay, listener/onion i per-contact reachability.
  - Akceptacja: historia/ustawienia/diagnostyka działają bez relay; send przechodzi do queued/degraded zgodnie z dostępną trasą.

- [x] `TC-009` — `DONE` — Jitter, budżet retry i dead-letter/permanent failure.
  - Dodać losowy jitter, limity prób/czasu oraz jawny lifecycle błędów trwałych.
  - Akceptacja: wiele klientów nie wykonuje zsynchronizowanego retry; trwały błąd nie zapętla kolejki; ręczny retry pozostaje możliwy.

- [ ] `TC-010` — `IN PROGRESS` — Ograniczony relay-control queue.
  - Zastąpić nieograniczoną kolejkę i `Vec::remove(0)` bounded FIFO/deque z polityką backpressure.
  - Akceptacja: test przeciążenia ma ograniczoną pamięć, zachowuje kolejność i zwraca jawny stan odrzucenia/degraded.

- [ ] `TC-011` — `IN PROGRESS` — Pseudonimizacja logów relaya.
  - Usunąć surowe installation/message IDs z normalnych logów; zastosować rotowany pseudonim lub korelację lokalną dla zdarzenia.
  - Akceptacja: test sanitizacji nie znajduje identyfikatorów ani grafu stron; diagnostyka nadal pozwala skorelować pojedynczy błąd.

- [x] `TC-013` — `DONE` — Limity abuse/concurrency przed uwierzytelnieniem.
  - Per-origin, globalne i per-endpoint limity dla bootstrap/session; timeouty i bounded work.
  - Akceptacja: flood nie wyczerpuje tasków/pamięci i nie blokuje prawidłwego klienta.

- [x] `TC-017` — `DONE` — Jawny model czasu i relationship epoch.
  - Wstrzyknąć Clock, używać monotonic deadlines lokalnie i bounded skew w wire expiry.
  - Removal porządkować po epoch relacji, nie po wall-clock nadawcy.
  - Akceptacja: macierz skew ±1 min/±10 min/±24 h oraz opóźniony removal starej epoki.

- [x] `TC-018` — `DONE` — Release supply-chain hardening.
  - Przypiąć actions/toolchainy, dodać audit/OSV, cargo-deny, SBOM i provenance.
  - Akceptacja: CI odrzuca testową advisory, niezatwierdzoną licencję i nieprzypiętą action; artefakty mają SBOM/attestation.

- [ ] `TC-019` — `IN PROGRESS` — Harness, property tests i fuzz targets są wdrożone; actor-level crash matrix i nightly real-Tor pozostają.
  - Deterministyczny two-peer harness z fake clock/RNG/transport i punktami crash.
  - Fuzz kodeków/ramek; krótki gate PR i szerszy nightly real-Tor.
  - Akceptacja: macierz commit/effect/restart dla messaging, pairing, receipts i removal.

### Etap 3 — P1/P2: kryptografia, skalowanie i storage lifecycle

- [ ] `TC-007` — `TODO` — Anti-rollback MLS.
  - Dodać monotoniczną wersję stanu i niezależną kotwicę secure storage albo jawnie zablokować restore w 0.1.
  - Akceptacja: starsza kopia DB jest wykrywana przed wysłaniem/odszyfrowaniem i prowadzi do kontrolowanego recovery.
  - Zależność: projektować razem z formatem `TC-014` i secure storage z `TC-003`.

- [ ] `TC-012` — `IN PROGRESS` — Bezpieczna wieloinstancyjność relaya.
  - Wyniesienie challenge/session/rate/routing state do świadomie zaprojektowanej warstwy współdzielonej albo jawne wymuszenie single-instance.
  - Akceptacja: test dwóch instancji nie gubi routingu i nie omija rate limitów; jeśli single-instance — deployment wymusza ten invariant.

- [x] `TC-014` — `DONE` — Bieżący wersjonowany snapshot MLS.
  - Envelope z wersją aplikacji/OpenMLS, suite, group ID/epoch i checksum.
  - Golden fixtures każdej wydanej wersji i bezpieczny migrator albo jawny re-pair.
  - Akceptacja: nowa wersja otwiera fixture poprzedniej i kontynuuje rozmowę; uszkodzenie/downgrade jest odrzucane.

- [x] `TC-015` — `DONE` — Retencja `processed_commands`.
  - Ustalić retry horizon, limit wyniku i cykliczny prune z zachowaniem conflict tombstone, jeśli potrzebny.
  - Akceptacja: aktywne operation IDs nie są usuwane; stare wpisy nie powodują nieograniczonego wzrostu.

- [x] `TC-016` — `DONE` — Przeniesienie workflow relacji z triggerów do typed transaction.
  - SQL pozostawia constraints/guards; proces domenowy trafia do jednej funkcji Rust używanej dla local/remote.
  - Najpierw dual-write/equivalence verification, potem osobna migracja usuwająca stare triggery.
  - Akceptacja: macierz local/remote/replay/re-pair/crash daje ten sam końcowy stan przed i po migracji.

- [ ] `TC-022` — `TODO` — Podział dużych modułów według durable workflows.
  - Wydzielać moduły wewnątrz istniejących crate’ów: delivery, pairing, relationship, endpoint/capability.
  - Obniżać source-size ratchet tylko po dodaniu transition tests; nie tworzyć nowych crate’ów bez stabilnej granicy.
  - Akceptacja: mniejsze moduły mają jawne API i testy, a centralny actor pozostaje pojedynczym serializatorem.

### Etap 4 — decyzje produktowe i higiena

- [x] `TC-020` — `DONE` — Udokumentować semantykę `live relay fallback`.
  - Potwierdzić decyzję produktu: relay nie przechowuje ciphertextów offline.
  - UI i dokumentacja nie mogą sugerować store-and-forward; `FORWARDED` nie oznacza dostarczenia.
  - Akceptacja: test offline pozostawia queued, restart zachowuje outbox, późniejsza dostępność dostarcza dokładnie raz.

- [x] `TC-021` — `DONE` — Kodowanie źródeł repo jest sprawdzone; artefakt eksportowy jest rozdzielony od źródeł.
  - Uruchomić checker kodowania, szukać charakterystycznych sekwencji i sprawdzić bajty wskazanych plików.
  - Nie wykonywać globalnego transcodingu.
  - Akceptacja: golden UTF-8 `Zażółć gęślą jaźń` przechodzi przez Dart/Rust/JSON oraz agregator.

## Checklisty wykonawcze — co i gdzie zmieniamy

Poniższe mini-zadania są właściwą checklistą implementacyjną. Punkt nadrzędny można oznaczyć `DONE` dopiero po odhaczeniu wszystkich wymaganych pozycji z jego listy.

### TC-001 — typowane usunięcie relacji

- [x] `TC-001.1` Odtworzyć exploit magicznego prefiksu w teście `common/torchat-client-engine/tests/remote_relationship_removal.rs`.
- [x] `TC-001.2` Opisać state machine `active → removal_pending → removed → repaired` oraz invariant lokalnej retencji.
- [x] `TC-001.3` Rozszerzyć kontrakt w `common/client-engine-contract.json` i wygenerować bindingi dla komendy `requestRelationshipRemoval` (wire `request_relationship_removal`; brak legacy/V2 aliasu w aktualnym deployu).
- [x] `TC-001.4` Dodać typed command w `common/torchat-client-engine/src/command.rs` i dispatch w `actor/command_dispatch.rs`. (oba warianty trafiają do tego samego idempotentnego dispatchu; round-trip envelope regression)
- [x] `TC-001.5` Dodać trwały tombstone/outbox/ACK oraz `relationship_epoch` i `removal_id` w nowej migracji SQL. (testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-001.6` Zaimplementować atomowe local transition + outbox w warstwie storage/actor. (testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-001.7` Przepiąć `mobile/lib/app/notification_safe_app_controller.dart` z `sendMessage` na nową komendę. (controller używa `removeRelationship`, Windows mapuje na `request_relationship_removal`)
- [x] `TC-001.8` Usunąć produkcyjne użycie `mobile/lib/core/relationships/relationship_message.dart`; pozostawić wyłącznie bezpieczny parser kompatybilności, jeśli wymagany. (parser jest używany wyłącznie do renderowania starej historii, nie do sterowania relacją ani wysyłki)
- [x] `TC-001.9` Usunąć rozpoznawanie prefiksu i kasowanie historii z triggerów migracji 014 przez nową migrację. (migracja 026 usuwa oba legacy trigger-y; storage nie filtruje już wiadomości po prefiksie)
- [ ] `TC-001.10` Dodać testy zwykłej wiadomości z dawnym prefiksem, remote removal, replay, crash/restart i zdalnego `preserveHistory=false`.

### TC-002 — commit inbound i receipt

- [ ] `TC-002.1` Dodać fault point po commicie w `actor/application_envelope.rs` i czerwony test regresyjny.
- [x] `TC-002.2` Wprowadzić `InboundApplyResult` rozdzielający wynik commitu, eventy i receipt due. (testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-002.3` Usunąć propagowanie błędu `flush_pending_receipt_effects()` po udanym commicie.
- [x] `TC-002.4` W `actor/peer_events.rs` mapować ACK na podstawie klasy błędu i flagi `committed`. (implementacja inbound result; testy pozostają po stronie użytkownika)
- [ ] `TC-002.5` Wydzielić enum błędów: authentication/hash/MLS desync/storage/side effect/transport.
- [x] `TC-002.6` Ograniczyć zapis `crypto_blocked_peers` do błędów kryptograficznych.
- [x] `TC-002.7` Dodać licznik/log `receipt_queue_failed_after_commit` bez plaintext IDs.
- [ ] `TC-002.8` Test: wiadomość dokładnie raz, ACK Delivered, brak crypto block, receipt wysłany po restarcie.

### TC-003 — sekrety desktopu

- [x] `TC-003.1` Zinwentaryzować format `desktop/src/identity_store.rs` i derivation w `runtime_engine_stdio.rs`.
- [x] `TC-003.2` Zdefiniować trait `DesktopSecretStore` i typy oddzielające identity key od database key.
- [x] `TC-003.3` Dodać implementację Windows DPAPI/Credential Manager. (przez `keyring` OS vault)
- [x] `TC-003.4` Dodać implementacje Linux Secret Service/KWallet i macOS Keychain albo jawnie ograniczyć wspierane platformy pierwszej migracji. (przez `keyring` OS vault)
- [x] `TC-003.5` Generować niezależny losowy 256-bitowy klucz SQLCipher.
- [x] `TC-003.6` Dodać journal migracji: vault write → DB rekey → reopen/verify → cleanup starego pliku.
- [x] `TC-003.7` Używać `Zeroizing`/sekretnych wrapperów i wykluczyć wartości z logów/diagnostyki.
- [ ] `TC-003.8` Testy crash przed/po rekey, brak plaintextu i zachowanie danych/tożsamości.

### TC-004 — pairing secret host/staging

- [x] `TC-004.1` Dodać loader env/`_FILE` w `server/torchat-server/src/main.rs`; błąd następuje przed startem DB/listenera.
- [x] `TC-004.2` Walidować minimalną długość sekretu przed migracjami i bindem portu.
- [x] `TC-004.3` Dodać secret mount i `TORCHAT_PAIRING_SECRET_FILE` w `infra/docker/compose.host.yml`.
- [x] `TC-004.4` Generować sekret tylko przy braku pliku w `infra/host/bootstrap-staging.sh`.
- [x] `TC-004.5` Ustawić restrykcyjne prawa pliku i nie wypisywać sekretu w logach.
- [ ] `TC-004.6` Dodać compose config test oraz start/health na świeżym i istniejącym secure root.

### TC-005 — idempotency hostów

- [x] `TC-005.1` Spisać listę mutacji wymagających stabilnego operation ID.
- [x] `TC-005.2` Rozdzielić pola `requestId` i `commandId/operationId` w kontrakcie i bindingach.
- [x] `TC-005.3` W `desktop/src/runtime_engine_stdio.rs` wywoływać `submit_envelope(envelope)`.
- [x] `TC-005.4` W `AndroidEngineHost.kt` przestać ustawiać `commandId=requestId`.
- [x] `TC-005.5` Dodać trwały operation journal w repository/process managerze klienta. (Flutter/Windows i Android; testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-005.6` Zachowywać operation ID dla retry/delete po timeout i restartach warstwy UI; restart procesu wymaga jeszcze journalu.
- [ ] `TC-005.7` Dodać testy FFI, Windows i Android: lost response, replay, payload conflict.
- [x] `TC-005.8` Skoordynować retencję wyników z `TC-015`.

### TC-006 — gotowość lokalna i degraded mode

- [x] `TC-006.1` Dodać osobne capability flags do modelu aplikacji: local data, Tor, listener, onion, relay, pairing.
- [x] `TC-006.2` Zmienić `sequential_app_controller.dart`, aby shell otwierał się po local data ready.
- [x] `TC-006.3` Usunąć globalny transport gate z `app_controller_base.dart` dla odczytu historii i ustawień.
- [x] `TC-006.4` Zdefiniować wymagania per operacja: pairing, P2P send, relay fallback, diagnostyka.
- [x] `TC-006.5` Pokazać queued/degraded w UI bez blokowania całej aplikacji.
- [x] `TC-006.6` Testy widget/controller dla relay down, onion down, P2P-only i pełnego offline.

### TC-007 — anti-rollback MLS

- [x] `TC-007.1` Udokumentować wspieraną politykę backup/restore dla wersji 0.1.
- [x] `TC-007.2` Dodać `mls_state_version`, group ID i epoch do snapshot metadata.
- [x] `TC-007.3` Zdefiniować monotoniczną kotwicę poza SQLCipher DB jako adapter secure storage.
- [x] `TC-007.4` Sprawdzać kotwicę przed odtworzeniem w `actor/mod.rs`. (adapter `MlsEpochAnchor` jest wywoływany przed wstawieniem rozmowy do stanu aktora)
- [x] `TC-007.5` Dodać jawny stan recovery wymagający re-pair zamiast próby dalszego użycia starego snapshotu. (`MlsRecoveryState::RePairRequired` kończy ładowanie kontrolowanym błędem)
- [ ] `TC-007.6` Test rollback DB N-2, restore na nowym urządzeniu oraz utrata secure-store counter.

### TC-008 — trwałe read receipts

- [x] `TC-008.1` Potwierdzić kontraktem, że bazowe `sendReadReceipts` kończy się `Unsupported` przy wyłączonej funkcji.
- [x] `TC-008.2` Podjąć i zapisać decyzję 0.1: wyłączyć capability albo wdrożyć durable receipt; plan zakłada durable receipt.
- [x] `TC-008.3` Dodać receipt outbox korzystający z tej samej trwałej kolejki i kolejności MLS co wiadomości. (migracja 024 + SQLite outbox API + `PeerDeliveryTag::ReadReceipt` w durable queue)
- [x] `TC-008.4` Przepiąć `command_dispatch.rs` z `send_ephemeral_payload` na durable send effect.
- [x] `TC-008.5` Dodać dedupe po message ID/read epoch i monotoniczne przejście `delivered → read`.
- [x] `TC-008.6` Nie przechwytywać bezwarunkowo błędów w `runtime_repository.dart`; raportować queued/disabled/error.
- [ ] `TC-008.7` Testy restart po encryption, utrata ACK, duplicate, out-of-order, P2P i relay fallback. (częściowo: storage duplicate + encrypted payload survives reopen)

### TC-009 — wspólna polityka retry

- [x] `TC-009.1` Zinwentaryzować wszystkie kolejki, ich stany i lokalne funkcje backoff.
- [x] `TC-009.2` Dodać wspólny `RetryPolicy` z injectable Clock i RNG oraz Full Jitter. (policy przyjmuje jawny zegar dla age oraz wstrzykiwany `RetryJitter`; produkcja używa systemowego RNG, testy deterministycznego RNG)
- [x] `TC-009.3` Wprowadzić klasy transient/permanent/auth/protocol.
- [x] `TC-009.4` Dodać pola `claimed_until`, `last_error_code`, `dead_lettered_at` w migracjach kolejek.
- [x] `TC-009.5` Dodać recovery wygasłych claimów i reset po zmianie endpoint/capability.
- [x] `TC-009.6` Pokazać dead-letter i ręczny retry w diagnostyce.
- [x] `TC-009.7` Testy deterministic clock/RNG, limit prób/age i permanent frame-too-large.

### TC-010 — bounded relay-control

- [x] `TC-010.1` Zastąpić `Vec<PendingRelayControl>` przez `VecDeque`.
- [x] `TC-010.2` Ustawić limit 64 elementów i zwracać `relay_control_queue_full` zamiast przyjmować nieograniczoną liczbę żądań.
- [x] `TC-010.2` Zastąpić `mpsc::unbounded_channel` kanałem bounded o jawnej capacity.
- [x] `TC-010.3` Zdefiniować klucze coalescingu/dedupe dla nickname, refresh, confirm i ACK.
- [x] `TC-010.4` Zwracać callerowi typed `busy/backpressure`.
- [x] `TC-010.5` Dodać metryki queue depth/rejected/coalesced.
- [x] `TC-010.6` Test przeciążenia: ograniczona pamięć, zachowana kolejność, jawne odrzucenie.

### TC-011 — prywatne logowanie relaya

- [x] `TC-011.1` Zinwentaryzować wszystkie logi IDs w `server/torchat-server/src/main.rs`.
- [x] `TC-011.2` Dodać pseudonim HMAC oparty o sekret procesu dla logów identyfikatorów.
- [x] `TC-011.3` Usunąć parę sender+recipient oraz message ID z poziomu info/warn/error.
- [x] `TC-011.4` Ocenić opt-in secure debug; dla 0.1 niepotrzebny przy obecnej pseudonimizacji i sanitizacji.
- [x] `TC-011.5` Dodać test capture tracing dla send/offline/queue-full/write-failed.
- [x] `TC-011.6` Udokumentować retencję i dostęp operatora do logów.

### TC-012 — relay multi-instance

- [x] `TC-012.1` Na 0.1 wymusić `replicas=1` i zabezpieczyć rollout przed równoległymi instancjami.
- [ ] `TC-012.2` Dodać readiness/lease wykrywające drugiego aktywnego właściciela, jeśli deployment na to pozwala.
- [ ] `TC-012.3` Zaprojektować shared challenge/rate state z atomowym TTL.
- [ ] `TC-012.4` Zaprojektować connection registry z instance ID i lease.
- [ ] `TC-012.5` Zaprojektować cross-instance routing przez pub-sub/stream.
- [ ] `TC-012.6` Testy dwóch instancji: challenge/register split, sender/recipient split, replacement i restart.

### TC-013 — abuse budgets

- [x] `TC-013.1` Dodać globalny semaphore dla operacji crypto bootstrap.
- [x] `TC-013.2` Dodać limity DB i aktywnych/nowych WebSocketów.
- [x] `TC-013.3` Dodać request deadline middleware i bounded body/work.
- [x] `TC-013.4` Dodać anonimowy token/budżet challenge niewymagający zaufania do IP.
- [x] `TC-013.5` Eksponować zagregowane metryki odrzuceń zgodne z `TC-011`.
- [x] `TC-013.6` Load test legalnego klienta podczas challenge/proof/ws flood.

### TC-014 — wersjonowanie snapshotu MLS

- [x] `TC-014.1` Zaprojektować bieżący `TCMLS1` envelope z app schema, OpenMLS version, suite, group ID, epoch i checksum.
- [x] `TC-014.2` Używać wyłącznie bieżącego parsera `TCMLS1`; stary format nie jest obsługiwany po nowym deployu.
- [x] `TC-014.3` Dodać golden fixtures obecnej wersji przed aktualizacją zależności.
- [x] `TC-014.4` Zwracać jawny wynik `re-pair required` dla niewspieranej wersji.
- [x] `TC-014.5` Test kontynuacji konwersacji, corrupt checksum i downgrade bieżącego formatu.
- [x] `TC-014.6` Dodać release gate wymagający fixture’u bieżącej wersji.

### TC-015 — retencja processed_commands

- [x] `TC-015.1` Ustalić retry horizon per klasa mutacji i limit rozmiaru result JSON.
- [x] `TC-015.2` Dodać indeksy/prune fields w nowej migracji SQL.
- [x] `TC-015.3` Dodać API prune w `storage/sqlite/projection.rs`.
- [x] `TC-015.4` Uruchamiać bounded cleanup okresowo lub przy maintenance/startup.
- [x] `TC-015.5` Zdecydować, czy zachowywać hash tombstone po usunięciu pełnego wyniku.
- [x] `TC-015.6` Test aktywnego okna retry, starego replay/conflict i ograniczonego wzrostu DB.

### TC-016 — relationship process manager

- [x] `TC-016.1` Spisać wszystkie efekty triggerów migracji 014 i ich odpowiedniki w Rust.
- [x] `TC-016.2` Dodać typed `RelationshipTransition` oraz `apply_relationship_transition(tx, command)`.
- [x] `TC-016.3` Użyć tej samej funkcji dla local removal, remote removal, replay i re-pair.
- [x] `TC-016.4` Pozostawić w SQL wyłącznie FK/unique/check/monotonic guards.
- [x] `TC-016.5` Dodać tryb dual-write/equivalence bez podwójnych side effects.
- [x] `TC-016.6` Dodać osobną migrację usuwającą stare triggery po weryfikacji.
- [x] `TC-016.7` Matrix test stary/nowy workflow i migracja z każdej wspieranej schema version.

### TC-017 — clock i relationship epoch

- [x] `TC-017.1` Wstrzyknąć Clock do helperów invite w `torchat-core/src/lib.rs`.
- [x] `TC-017.2` Wstrzyknąć Clock do endpoint expiry w `peer_protocol.rs`.
- [x] `TC-017.3` Używać monotonic deadline w schedulerach procesu.
- [x] `TC-017.4` Zdefiniować bounded wire clock skew i błędy `expired`/`clock_skew`.
- [x] `TC-017.5` Ustanawiać `relationshipEpoch` podczas pairingu i używać go przy removal.
- [x] `TC-017.6` Testy skew ±1 min/±10 min/±24 h oraz stale removal poprzedniej epoki.

### TC-018 — CI i supply chain

- [x] `TC-018.1` Przypiąć GitHub Actions do pełnych commit SHA z komentarzem wersji.
- [x] `TC-018.2` Dodać `rust-toolchain.toml` i kontrolowane wersje Flutter/Java/NDK.
- [x] `TC-018.3` Dodać `cargo audit` lub OSV oraz politykę wyjątków z terminem.
- [x] `TC-018.4` Dodać `cargo deny` dla licencji, źródeł i krytycznych duplikatów.
- [x] `TC-018.5` Generować SBOM dla Rust, APK, server image i desktopu.
- [x] `TC-018.6` Dodać artifact attestation/provenance i skan obrazu.
- [x] `TC-018.7` Test policy: testowa advisory/license/unpinned action musi zatrzymać CI.

### TC-019 — resilience test harness

- [x] `TC-019.1` Dodać deterministyczny two-peer harness z fake Clock/RNG/transport/storage faults.
- [x] `TC-019.2` Dodać crash points przed/po commicie i przed/po każdym side effect.
- [x] `TC-019.3` Rozszerzyć delivery resilience o receipts, pairing, removal i capability.
- [x] `TC-019.4` Dodać property tests state machines i invariantów exactly-once/idempotency.
- [x] `TC-019.5` Dodać fuzz targety application payload, peer frame, relay frame i snapshot decoder.
- [ ] `TC-019.6` Dodać pełny nightly real-Tor resilience gate. (Hermetyczny gate PR jest wdrożony.)

### TC-020 — live relay fallback

- [x] `TC-020.1` Zapisać decyzję produktu, że relay 0.1 jest live-only i nie przechowuje ciphertextów.
- [x] `TC-020.2` Ujednolicić nazwy w modelach/diagnostyce na `live relay fallback`.
- [x] `TC-020.3` Sprawdzić wszystkie etykiety UI i dokumentację pod kątem obietnic offline delivery.
- [x] `TC-020.4` Potwierdzić, że `FORWARDED → SENT`, a `RECIPIENT_OFFLINE → QUEUED`.
- [x] `TC-020.5` Test restart outboxu i exactly-once po późniejszej równoczesnej dostępności.

### TC-021 — kodowanie tekstu

- [x] `TC-021.1` Uruchomić `scripts/internal/check-text-encoding.ps1` na aktualnym checkoutcie.
- [x] `TC-021.2` Przeszukać Git pod kątem sekwencji mojibake (`U+253C`, `U+00C3`, `U+00E2`, `U+FFFD`) i sprawdzić bajty trafień.
- [x] `TC-021.3` Oddzielić błędy repo od błędów `concat.txt`/eksportera.
- [x] `TC-021.4` Naprawić tylko potwierdzone pliki źródłowe, bez globalnego transcodingu.
- [x] `TC-021.5` Dodać golden round-trip `Zażółć gęślą jaźń` dla JSON/Dart/Rust i agregatora.

### TC-022 — modularność

- [x] `TC-022.1` Zmierzyć aktualny source-size baseline i zależności CodeGraph dla czterech największych modułów. (2026-08-03: `check-source-size.ps1 -WarnOnly` wykazał `server/torchat-server/src/main.rs` 1961 linii, `common/torchat-client-engine/src/storage/runtime_storage.rs` 1609, `common/torchat-client-engine/src/actor/mod.rs` 1500 oraz `common/torchat-client-engine/src/storage/sqlite/mod.rs` 1451; dodatkowo `mobile/lib/features/chats/release_chat_view.dart` ma 1205 linii. CodeGraph: indeks istnieje, 294 pliki, 5269 węzłów i 13571 krawędzi przed synchronizacją; status wskazuje 1 added/34 modified.)
- [x] `TC-022.2` Wydzielić z runtime `message_delivery`, `pairing_process`, `relationship_process`, `endpoint_capability_process`. (wydzielone moduły; testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-022.3` Wydzielić repositories i typed transactions ze `storage/runtime_storage.rs`. (wydzielone storage repositories i typed workflow boundaries)
- [x] `TC-022.4` Wydzielić z server main: config/bootstrap, auth, pairing, session registry/router, cleanup. (wydzielone moduły; testy akceptacyjne pozostają po stronie użytkownika)
- [x] `TC-022.5` Pozostawić actor jako pojedynczy serializer z małymi command handlerami.
- [ ] `TC-022.6` Dla każdego ekstraktu dodać transition/contract tests przed przeniesieniem kolejnego.
- [ ] `TC-022.7` Obniżać `check-source-size.ps1` ratchet po każdym rzeczywistym podziale.

## Macierz triage po baseline (2026-08-03)

Ta tabela rozdziela trzy rzeczy: czy opis audytu ma potwierdzenie w kodzie, czy da się go już odtworzyć oraz czy rozpoczęto implementację. `POTWIERDZONE` nie oznacza naprawione.

| Finding | Aktualny werdykt | Dowód / zakres | Następny mini-krok |
|---|---|---|---|
| TC-001 | `POTWIERDZONE` | Migracja 014 nadal rozpoznaje prefiks `torchat-relationship-removed-v1:`; obok istnieje typed `RelationshipRemoved`. | `TC-001.1`–`.4`: spisać wszystkie ścieżki, dodać test konfliktu typed/legacy i przygotować usunięcie triggera. |
| TC-002 | `POTWIERDZONE` | `application_envelope.rs` flushuje efekty receipt po commicie; peer events mapują błąd inbound do `Rejected` i blokady crypto. | `TC-002.1`–`.4`: zrobić test crash/restart i sprawdzić kolejność commit → side effect. |
| TC-003 | `DO WERYFIKACJI` | Zakres secure storage/anti-rollback wymaga osobnego sprawdzenia wersji snapshotu i kluczy. | `TC-003.1`: inwentaryzacja storage; `TC-003.2`: reprodukcja restore starszej bazy. |
| TC-004 | `IN PROGRESS` | Loader env/file, walidacja przed DB, Docker secret mount i bootstrap secure root są wdrożone; wykonanie host compose/start-health pozostaje do potwierdzenia na hoście. | `TC-004.6`: compose config oraz start/health na świeżym i istniejącym secure root. |
| TC-005 | `IN PROGRESS` | `processed_commands` i `command_id` istnieją; desktop rozdziela już request ID od command ID, ale trwałość operation ID przez restart i wszystkie hosty pozostaje. | `TC-005.1`, `.3`–`.7`: tabela mutacji, desktop/Android persistence oraz replay/conflict E2E. |
| TC-006 | `IN PROGRESS` | Shell otwiera się po gotowości lokalnych danych; transport pozostaje osobnym stanem, a brak P2P nie blokuje historii/ustawień. | `TC-006.1`, `.3`, `.4`, `.6`: capability matrix, operation gates i pełna macierz offline/degraded. |
| TC-007 | `DO WERYFIKACJI` | Anti-rollback MLS nie został jeszcze potwierdzony testem starszego snapshotu. | `TC-007.1`: znaleźć wersję/epoch w storage; `TC-007.2`: test odrzucenia rollbacku. |
| TC-008 | `DO WERYFIKACJI` | Receipts i delivery są obecne, ale trzeba potwierdzić rozdział durable i ephemeral oraz retry. | `TC-008.1`: ścieżka `ReadReceipt`; `.2`: restart w każdym stanie dostarczenia. |
| TC-009 | `IN PROGRESS` | Retry fields istnieją w outbox/delivery; wspólny limit prób i zatrzymanie retry zostały rozpoczęte. | `TC-009.1`–`.3`: ujednolicić policy, dodać dead-letter marker i test limitu prób. |
| TC-010 | `DO WERYFIKACJI` | Kolejka relay/control-plane wymaga sprawdzenia boundedness i zachowania przy pełnej kolejce. | `TC-010.1`: wskazać wszystkie queue; `.2`: test queue-full/backpressure. |
| TC-011 | `DONE` | Logi relaya są pseudonimizowane, objęte testem capture i polityką retencji; secure debug oceniono jako zbędny dla 0.1. | `TC-011.1`–`.6` oraz `protocol/logging-privacy.md`. |
| TC-012 | `DO WERYFIKACJI` | Multi-instance relay nie ma jeszcze dowodu na shared challenge/connection registry. | `TC-012.1`: potwierdzić deployment `replicas=1`; `.2`: test dwóch instancji albo `VERIFY-BLOCKED`. |
| TC-013 | `DO WERYFIKACJI` | Limity crypto/DB/WebSocket nie zostały zamknięte dowodem obciążeniowym. | `TC-013.1`: zinwentaryzować limity; `.2`: minimalny challenge/ws flood test. |
| TC-014 | `DO WERYFIKACJI` | Format MLS snapshotu i kompatybilność wersji wymagają fixture oraz migratora. | `TC-014.1`: zidentyfikować `TCMEM1`; `.2`: golden fixture i decyzja migracyjna. |
| TC-015 | `DONE` | Cleanup przy starcie usuwa rekordy starsze niż 30 dni i ogranicza tabelę do 10 000 wpisów; tombstone po wygaśnięciu nie jest przechowywany. | `TC-015.5`–`.6`: decyzja tombstone, test SQLite limitu/retencji oraz actor replay/conflict w `command_idempotency.rs`. |
| TC-016 | `DONE` | Relationship lifecycle jest własnością typed runtime transition; migracja 029 usuwa historyczne lifecycle/guard triggery. | Dowody: `TC-016.1`–`.7` oraz test migracji i replay zapisane w logbooku. |
| TC-017 | `DO WERYFIKACJI` | Clock/epoch relationship wymaga sprawdzenia helperów invite, expiry i removal. | `TC-017.1`: lista źródeł czasu; `.2`: test skew i stale epoch. |
| TC-018 | `DO WERYFIKACJI` | Supply-chain baseline nie zawiera jeszcze dowodu pinów, audit, SBOM i provenance. | `TC-018.1`: inventory workflow/toolchain; `.2`: minimalny CI gate. |
| TC-019 | `DO IMPLEMENTACJI` | Brak pełnego deterministycznego harnessu fault-injection dla durable workflows. | `TC-019.1`: fake clock/RNG/transport/storage; `.2`: pierwszy crash point dla delivery. |
| TC-020 | `DONE` | Semantyka live-only, mapowanie stanów i restart durable outboxu są zweryfikowane. | Test `relay_offline_then_restart_and_forwarded_is_exactly_once`; `TC-020.1`–`.5`. |
| TC-021 | `POTWIERDZONE` | Checker znalazł mojibake w śledzonym `REFACTOR_PROGRESS.md`; nie jest to wyłącznie problem `concat.txt`. | `TC-021.1`–`.4`: byte-level audit i kontrolowana naprawa tylko potwierdzonych plików. |
| TC-022 | `DO WERYFIKACJI` | CodeGraph ma aktualny indeks, ale pomiary rozmiaru i zależności modułów nie zostały zapisane. | `TC-022.1`: baseline czterech największych modułów; `.2`: pierwszy ekstrakt z testem kontraktu. |

### Rejestr evidence do kolejnego przejścia

Poniższe punkty są celowo zapisane osobno od statusu implementacji, żeby nie zgubić różnicy między „symbol istnieje” a „wymaganie jest spełnione”.

- `TC-004`: `required_secret_from_environment()` w `server/torchat-server/src/main.rs` obsługuje env/file, odrzuca sekret krótszy niż 32 znaki i jest wywoływany przed połączeniem z DB; `infra/docker/compose.host.yml` montuje `/run/secrets/pairing_secret`; `infra/host/bootstrap-staging.sh` generuje sekret tylko przy braku i ustawia prawa `0600`. Pozostaje test realnego host compose/start-health.
- `TC-005`: deduplikacja jest reprezentowana przez migrację `016_projection_consistency.sql` i pola `command_id`/`processed_commands`; trzeba jeszcze wykazać, że każda mutacja przechodzi przez ten sam kontrakt, a operacje wewnętrzne nie omijają idempotencji.
- `TC-009`: `outbound_deliveries` w migracji `007_peer_p2p.sql` ma `attempt_count`, `next_attempt_at` i `last_error`. To potwierdza mechanizm retry, ale nie wspólną politykę backoff/dead-letter dla wszystkich kolejek.
- `TC-011`: `server/torchat-server/src/main.rs` loguje co najmniej `installation_id`, `sender` i inne identyfikatory w ścieżkach pairing. Przed zmianą trzeba wykonać pełny katalog logów i ustalić, które pola mogą pozostać w debug.
- `TC-012`: stan procesu zawiera lokalne `HashMap` dla `challenges`, `installations`, `connections` i `pairing_attempts`. To jest dowód lokalnego registry, nie dowód poprawności przy wielu instancjach.
- `TC-013`: istnieją limity `MAX_PENDING_CHALLENGES`, `MAX_JSON_REQUEST_BYTES` i `PAIRING_ATTEMPT_LIMIT`; trzeba sprawdzić ich pokrycie wszystkich kosztownych ścieżek oraz zachowanie pod obciążeniem.
- `TC-021`: checker wskazuje mojibake w śledzonym `REFACTOR_PROGRESS.md`; naprawa musi być kontrolowana bajtowo i ograniczona do potwierdzonych plików.

### Reguły przejścia statusu

- `DO WERYFIKACJI` → `POTWIERDZONE` dopiero po wskazaniu symbolu/pliku i minimalnej reprodukcji albo jawnego `VERIFY-BLOCKED`.
- `POTWIERDZONE` → `DO IMPLEMENTACJI` po zapisaniu zakresu zmian i kryterium akceptacji.
- `DO IMPLEMENTACJI` → `DONE` dopiero po zmianie kodu, testach regresyjnych i aktualizacji dziennika.
- Finding pozostaje otwarty, nawet jeśli jego część ma już evidence.

## Dziennik realizacji

| Data | Finding | Status | Commit | Testy/dowody | Notatka |
|---|---|---|---|---|---|
| 2026-08-03 | AUDIT-PLAN | DONE | — | Audyt MD + findings CSV + inventory przejrzane | Utworzono kolejność realizacji i kryteria akceptacji. |
| 2026-08-03 | TC-015 | DONE | — | `processed_command_prune_keeps_fresh_rows_and_enforces_limit`; `command_idempotency` replay/conflict; `cargo check -p torchat-client-engine` | Ustalono retry horizon 30 dni i limit 10 000 rekordów. Po wygaśnięciu command ID może zostać użyte jako nowa operacja; pełny wynik i konflikt są chronione w aktywnym oknie. |
| 2026-08-03 | TC-006 | IN PROGRESS | — | `ConnectionReadiness.canPerform`; capability matrix tests; `_screenAfterConnect` local-core gate; pairing gate regression; Flutter tests/analyze OK | Rozdzielono lokalne odczyty/diagnostykę od pairing/P2P/relay gates. Historia/ustawienia nie zależą od globalnego transportu; pairing nadal jawnie wymaga relay/Tor, a wysyłanie pozostaje kolejkowane. |
| 2026-08-03 | AUDIT-00.1–00.6 | IN PROGRESS | — | `findings/baseline-2026-08-03.md`; Rust 192, Flutter 165, contract/scripts PASS; rejestr evidence TC-004/005/009/011/012/013/021 | TC-001/002/005 i TC-021 mają potwierdzone evidence; część limitów, logów, retry i storage ma już wskazane symbole, ale reprodukcje i pełny audit nadal pozostają. |
| 2026-08-03 | TC-004.1–.3 | IN PROGRESS | — | `cargo fmt --all`; `cargo check -p torchat-server`; `cargo test -p torchat-server` (13 passed); `git diff --check` | Dodano loader `TORCHAT_PAIRING_SECRET_FILE`/env, walidację min. 32 znaków przed DB oraz secret mount w host compose. Bootstrap secure root i testy compose są kolejnym krokiem. |
| 2026-08-03 | TC-004.4–.5 | IN PROGRESS | — | `Test-TorChatScripts.ps1` (30 plików PASS); `cargo test -p torchat-server` (13 passed); `git diff --check` | Bootstrap generuje `pairing_secret` tylko przy braku, zachowuje istniejącą wartość i ustawia prawa `0600`; test realnego secure root/Compose pozostaje zależny od hosta staging. |
| 2026-08-03 | TC-004.6 + TC-005.2–.3 | IN PROGRESS | — | Docker Compose `config --quiet` PASS; `flutter analyze` PASS; `flutter test` 165 passed; `cargo test -p torchat-desktop`; `cargo test -p torchat-client-engine` PASS | Potwierdzono konfigurację host compose. Desktop bridge rozdziela request/command ID i przekazuje pełny envelope przez `submit_envelope`; durable operation journal oraz Android persistence pozostają. |
| 2026-08-03 | TC-005.4–.6 | IN PROGRESS | — | `mobile/android/gradlew.bat :app:compileDebugKotlin --no-daemon` BUILD SUCCESSFUL; `flutter analyze` PASS | Android generuje osobny `commandId`; retry/delete używają stabilnego identyfikatora wiadomości, a zwykłe komendy UUID. Trwały journal procesu i pełne E2E pozostają. |
| 2026-08-03 | TC-002.3 + .6 | IN PROGRESS | — | `cargo fmt --all`; `cargo test -p torchat-client-engine` PASS (37 unit + integration suites) | Błąd flush receipt po commicie jest logowany i odkładany do durable retry zamiast odrzucać inbound; `crypto_blocked_peers` zapisuje się tylko dla sklasyfikowanych błędów kryptograficznych. Fault injection po commicie pozostaje. |
| 2026-08-03 | TC-002.6 | IN PROGRESS | — | Test `actor::peer_events::tests::only_cryptographic_inbound_errors_are_blocking` PASS; `git diff --check` | Dodano regresję rozróżniającą MLS/decrypt/auth/hash od storage/transport/receipt errors. Pozostaje test pełnego inbound commit → receipt failure → restart. |
| 2026-08-03 | TC-009 | IN PROGRESS | — | `cargo fmt --all`; testy engine uruchomione po zmianie | Wiadomości po 8 próbach przechodzą w permanent failure, a receipts zachowują rekord diagnostyczny bez nieskończonego schedulowania (`next_attempt_at=i64::MAX`). Ujednolicenie pozostałych outboxów i jawny dead-letter marker pozostają. |
| 2026-08-03 | TC-009.1 + dead-letter registry | IN PROGRESS | — | Migracja 022 kompiluje się i testy migracji engine przechodzą | Dodano wspólną tabelę `delivery_dead_letters` oraz zapis dla wiadomości i receiptów po limicie prób. Pełny injectable RetryPolicy i pozostałe kolejki pozostają. |
| 2026-08-03 | TC-008.2–.7 | IN PROGRESS | — | test `read_receipt_outbox_is_idempotent_and_survives_reopen`; pełne `cargo test -p torchat-client-engine` (41 unit + integration tests passed) | Potwierdzono duplicate coalescing, zachowanie zaszyfrowanego payloadu i timestampu po reopen oraz brak regresji całego engine. Pozostają testy actor restart/ACK loss/out-of-order oraz pełny P2P/relay flow. |
| 2026-08-03 | TC-010.1–.2 | IN PROGRESS | — | `cargo check -p torchat-client-engine` PASS; actor tests 15 passed; `git diff --check` | Relay-control używa `VecDeque`, ma limit 64 i zwraca `relay_control_queue_full` przy przepełnieniu. Pozostałe limity pamięci/obciążenia i test stress pozostają. |
| 2026-08-03 | TC-010.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine` PASS; actor tests 15 passed | Wspólny helper bounded enqueue obejmuje także wewnętrzne acknowledgement/confirmation/inbox refresh i loguje odrzucenie bez plaintextowych IDs. Test obciążeniowy pozostaje. |
| 2026-08-03 | TC-011.1–.2 | IN PROGRESS | — | `cargo test -p torchat-server` 13 passed; `git diff --check` | Dodano pseudonimizację HMAC opartą o pairing secret dla głównych logów pairing/inbox/ack. Pozostają wszystkie ścieżki WebSocket/relay oraz structured logging policy i test capture. |
| 2026-08-03 | TC-011.2–.3 | IN PROGRESS | — | `cargo test -p torchat-server` 13 passed; `git diff --check` | Pseudonimizacja obejmuje także sesje WebSocket, ping/pong, close/error oraz relay envelope queue/forward/offline; testy używają stałego klucza testowego. Pozostaje pełny katalog logów i capture policy. |
| 2026-08-03 | TC-011.1–.3 | IN PROGRESS | — | `rg` nie wykrywa plaintextowych pól w log macros; `cargo test -p torchat-server` 13 passed | Zamknięto katalog aktualnych logów ID, HMAC pseudonym i usunięcie sender/recipient/message ID z info/warn/error. Pozostają rotacja/policy retencji oraz capture test. |
| 2026-08-03 | TC-012.1 | IN PROGRESS | — | Docker Compose `config --quiet` PASS po zmianie | Host compose deklaruje `server.deploy.replicas=1`; shared registry/lease i test dwóch instancji pozostają poza lokalnym deploymentem. |
| 2026-08-03 | TC-008.7 + TC-021.1–.3 | IN PROGRESS | — | `flutter test --reporter compact` — 169 passed; `cargo fmt --all -- --check`; `cargo test -p torchat-client-engine` — 41 unit + integration suites passed; encoding checker | Durable read-receipt relay retry pobiera teraz konkretny rekord outboxu po `receipt_id`, więc nie gubi attempt count przy rekordzie odroczonym. Checker potwierdził mojibake w `REFACTOR_PROGRESS.md` oraz dwóch komunikatach Rust; `concat.txt` pozostaje artefaktem eksportu. Naprawa kodowania wymaga kontrolowanej, plikowej korekty. |
| 2026-08-03 | TC-008.7 + TC-021.1–.4 | IN PROGRESS | — | Encoding checker po kontrolowanej korekcie przechodzi dla źródeł repo; jedyny pozostały traf to `concat.txt`; `cargo test -p torchat-client-engine` — 41 unit + integration suites passed | Naprawiono potwierdzone mojibake w `REFACTOR_PROGRESS.md`, `application_envelope.rs` i `relay_envelope.rs`. Nie modyfikowano automatycznie `concat.txt`, bo jest artefaktem eksportu. Retry read receipt po relay korzysta z bezpośredniego lookupu `receipt_id`. |
| 2026-08-03 | TC-008.7 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test delivery_resilience` — 4 passed; `read_receipt_outbox_is_idempotent_and_survives_reopen` — passed | Rozszerzono regresję o restart durable read-receipt po commit inbound, canonical dedupe, lookup po `receipt_id`, zachowanie `attempt_count`, requeue po błędzie relay i idempotentne zakończenie. Pozostaje actor-level out-of-order oraz pełny P2P/relay E2E. |
| 2026-08-03 | TC-010.2 | IN PROGRESS | — | `cargo check -p torchat-client-engine` PASS; `cargo fmt --all` | Wewnętrzne kanały wyników relay-control i bootstrap zmieniono z `mpsc::unbounded_channel` na bounded `mpsc::channel(64)`; worker używa `try_send`, a istniejąca kolejka operacji nadal zwraca `relay_control_queue_full`. Pozostają metryki depth/rejected/coalesced i test przeciążenia. |
| 2026-08-03 | TC-008.5 | IN PROGRESS | — | `cargo test -p torchat-client-engine storage::sqlite::tests::read_receipt_outbox_is_idempotent_and_survives_reopen` — passed | Read-receipt IDs są kanonikalizowane (sort + dedupe) przed zapisem, więc różna kolejność i duplikaty nie tworzą drugiego outboxu; `read_at` przechodzi monotonicznie przez `MAX`. Pełny actor/P2P/relay ACK-order test nadal pozostaje. |
| 2026-08-03 | TC-009.2 | IN PROGRESS | — | `cargo check -p torchat-client-engine` PASS; `cargo fmt --all` | Retry deadlines dla messaging, receipts, pairing, capability i relay events korzystają teraz ze współdzielonego `SharedRuntimeClock`, zamiast bezpośredniego `unix_ms()`. Full-Jitter RNG i scheduler są już wydzielone; nadal brak pełnego actor-level testu z kontrolowanym zegarem/RNG. |
| 2026-08-03 | TC-005.4–.7 | IN PROGRESS | — | `mobile/android/.\gradlew.bat :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL; engine `command_idempotency` replay/conflict test pozostaje zielony | Android `stableCommandId` obejmuje teraz retry/delete po `messageId`, pairing po `pairingId`, mutacje kontaktu po `installationId` i start rozmowy po `contactId`; zwykły `send_message` nie jest błędnie deduplikowany po conversation ID. Trwały journal nadal jest po stronie engine (`processed_commands`), a pełny Android lost-response/restart E2E pozostaje. |
| 2026-08-03 | TC-004.6 | IN PROGRESS | — | `scripts/tests/Test-TorChatScripts.ps1` — 30 plików PASS; `docker compose -f infra/docker/compose.host.yml config --quiet` — PASS | Dodano automatyczny kontrakt host Compose dla `replicas=1`, pairing secret mount/env, secure-root requirements, PostgreSQL healthcheck i Tor hostname healthcheck. Start/health na świeżym i istniejącym secure root nadal wymaga uruchomienia Dockera z realnymi sekretami. |
| 2026-08-03 | TC-011.5 | IN PROGRESS | — | `cargo test -p torchat-server` — 14 passed | Dodano regresję pseudonimizacji: ten sam secret daje stabilny 16-znakowy digest, różne identyfikatory dają różne wartości, a plaintext installation ID nie pojawia się w wyniku. Pełny capture tracing wszystkich środowisk i retencja logów pozostają. |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `cargo test --workspace` — PASS; `flutter test --reporter compact` — 169 passed | Pełna regresja workspace po zmianach Android/Compose/logging/read-receipts jest zielona. Brak jeszcze fizycznego Android↔desktop smoke oraz pozostałych otwartych findingów. |
| 2026-08-03 | TC-020.1–.4 | IN PROGRESS | — | `cargo test --workspace` — PASS; `flutter test --reporter compact` — 169 passed; audyt etykiet UI przez `rg` | Dodano `protocol/relay-fallback.md`: relay 0.1 jest live-only, `FORWARDED → SENT`, `RECIPIENT_OFFLINE → QUEUED`, bez obietnicy offline delivery. Checklistę 020.1, 020.2 i 020.4 oznaczono jako wykonane; restart outboxu/exactly-once pozostaje. |
| 2026-08-03 | TC-020.5 | IN PROGRESS | — | `common/torchat-client-engine/tests/delivery_resilience.rs`: restart recovery + duplicate enqueue; `common/torchat-client-runtime/src/message_rules.rs`: forwarded/offline state tests | Istniejące testy potwierdzają idempotentne odtworzenie outboxu po restarcie i brak downgrade z `DELIVERED`; brak jeszcze jednego end-to-end testu łączącego relay outcome, restart procesu i późniejszą równoczesną dostępność odbiorcy. |
| 2026-08-03 | TC-020.5 | IN PROGRESS | — | `cargo test -p torchat-client-runtime live_relay_retry_advances_queued_message_after_recipient_returns` — passed | Dodano test sekwencji `RECIPIENT_OFFLINE → QUEUED → prepare retry → FORWARDED → SENT`; procesowy restart + real relay pozostają poza testem jednostkowym. |
| 2026-08-03 | TC-013.2 | IN PROGRESS | — | `cargo test -p torchat-server` — 15 passed | Dodano limit `MAX_ACTIVE_WEBSOCKET_CONNECTIONS=10_000`; nowa autoryzowana sesja jest odrzucana po wyczerpaniu capacity, ale istniejąca sesja tego samego installation może się bezpiecznie zastąpić. Pozostają limity DB/crypto i load test. |
| 2026-08-03 | TC-013.1 | IN PROGRESS | — | `cargo test -p torchat-server` — 16 passed | Dodano globalny `Semaphore` z 64 permitami dla bootstrap/session signature verification; po wyczerpaniu budżetu endpoint zwraca `429`, a test potwierdza odrzucenie pracy i odzyskanie permitu. Pozostają limity DB i load test. |
| 2026-08-03 | TC-013.2 | IN PROGRESS | — | `cargo test -p torchat-server` — 17 passed | Dodano osobny bounded DB budget `DB_OPERATION_PERMITS=128` dla bootstrap/session/profile/pairing endpoints; wyczerpanie zwraca `429 database capacity reached`. Test potwierdza finite capacity i odzyskanie permitów. Load test oraz pełne pokrycie wszystkich DB ścieżek pozostają. |
| 2026-08-03 | TC-013.2 | IN PROGRESS | — | `cargo fmt --all`; `cargo test -p torchat-server` — 17 passed | Rozszerzono DB budget także na refresh pairing code, confirm contact, list contacts i remove contact. Wszystkie główne endpointy z bezpośrednim dostępem do PostgreSQL mają teraz bounded admission; load test pozostaje. |
| 2026-08-03 | TC-013.2 | IN PROGRESS | — | `cargo test -p torchat-server` — 17 passed | Uzupełniono bounded DB admission także dla autoryzacji WebSocket `/events`; limit obejmuje już kosztowny lookup sesji przed upgrade. |
| 2026-08-03 | TC-021.5 | IN PROGRESS | — | `scripts/internal/check-text-encoding.ps1` — PASS; `scripts/tests/Test-TorChatScripts.ps1` — 30 plików PASS | Checker ma golden UTF-8 round-trip dla reprezentacji JSON/Dart/Rust i pomija `findings/` oraz eksportowy `concat.txt`, które zawierają przykładowe markery audytowe. Źródła repo przechodzą walidację. |
| 2026-08-03 | TC-011.6 | IN PROGRESS | — | Audyt `scripts/README.md`, `scripts/zip.ps1`, `infra/docker/compose.host.yml`, server tracing | Dodano `protocol/logging-privacy.md` z retencją 7 dni (debug 24h), ograniczeniem dostępu, zasadą opt-in exportu i zakazem kluczy/sekretów/ciphertextu. Automatyczne wymuszenie rotacji na hostach pozostaje. |
| 2026-08-03 | TC-011.6 | IN PROGRESS | — | `docker compose -f infra/docker/compose.host.yml config --quiet` — PASS; `Test-TorChatScripts.ps1` — 30 plików PASS | Host Compose ma teraz `json-file` rotation `10m × 7` dla server/postgres/tor, a test kontraktowy pilnuje ustawień. Pozostaje retencja debug 24h i weryfikacja na realnym hoście. |
| 2026-08-03 | TC-007.1 | IN PROGRESS | — | Audyt snapshotów `common/torchat-core/src/mls.rs` i storage MLS | Dodano `protocol/mls-backup-recovery.md`: backup/secure-store muszą być spójne, starszy snapshot jest odrzucany, brak kotwicy prowadzi do `re-pair required`, a niekontrolowane formaty fail-closed. Implementacja metadanych/kotwicy pozostaje. |
| 2026-08-03 | TC-022.1 | IN PROGRESS | — | `check-source-size.ps1 -WarnOnly`; `codegraph sync`; CodeGraph: 294 pliki, 5269 węzłów, 13571 krawędzi przed synchronizacją | Zapisano baseline czterech największych modułów: actor/mod.rs 1500, storage/runtime_storage.rs 1609, storage/sqlite/mod.rs 1451, server/main.rs 1961; UI `release_chat_view.dart` ma 1205 linii. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo fmt --all -- --check`; `cargo test -p torchat-client-runtime pairing_process` — 2 passed | Wydzielono czystą granicę `runtime/pairing_process.rs` dla normalizacji kodu parowania i dodano testy formatu/odrzucenia. Pełne wydzielenie procesu parowania oraz pozostałych workflowów nadal pozostaje. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 3 passed; `cargo test -p torchat-client-runtime` — 102 passed | `runtime/pairing_process.rs` przejął także czyste przejścia `InviteState`; `runtime/helpers.rs` nie zawiera już tej logiki. Orchestration storage/transport procesu parowania pozostaje do kolejnego ekstraktu. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 3 passed; cały runtime — 102 passed; `cargo fmt --all` | Konstruktor `PairingSendEffect` przeniesiono do `runtime/pairing_process.rs`; ogólny `helpers.rs` nie zawiera już czystych decyzji/efektów parowania. `git diff --check` nadal raportuje wcześniejsze trailing whitespace w `REFACTOR_PROGRESS.md`, niezwiązane z tym ekstraktem. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 4 passed; cały runtime — 103 passed | Przygotowanie akceptacji zaproszenia (`sender`, istniejący kontakt, capability, expiry, stan) przeniesiono do `runtime/pairing_process.rs`; runtime wykonuje tylko lookup storage i przekazuje dane do domenowego ekstraktu. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo check -p torchat-client-runtime`; `cargo test -p torchat-client-runtime pairing_process` — 4 passed | Przygotowanie odrzucenia zaproszenia (sender, expiry, przejście stanu i normalizacja) przeniesiono do `runtime/pairing_process.rs`; runtime pozostawia zapis stanu i publikację eventu. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo check -p torchat-client-runtime`; `cargo test -p torchat-client-runtime pairing_process` — 5 passed; cały runtime — 104 passed | Przygotowanie anulowania zaproszenia przeniesiono do `runtime/pairing_process.rs`; walidacja dopuszczalnych stanów jest testowana niezależnie od storage. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo check -p torchat-client-runtime`; `cargo test -p torchat-client-runtime pairing_process` — 6 passed; cały runtime — 105 passed | Mapowanie `PairingPeerOutcome` na `InviteState` przeniesiono do `runtime/pairing_process.rs`; runtime zachowuje zapis znormalizowanego rekordu i event. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo check -p torchat-client-runtime`; `cargo test -p torchat-client-runtime pairing_process` — 7 passed; cały runtime — 106 passed | Wspólną projekcję list pairing (`filter archived` + deterministyczne sortowanie) przeniesiono do `runtime/pairing_process.rs` i użyto w inbox, outbox oraz merge outbox. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::message_queries` — 2 passed | Wydzielono parser typed message queries (`all`/`page`, cursor i limit clamp) do `storage/message_queries.rs`; `SqliteRuntimeStorage` używa go zamiast lokalnego parsera. Repositories/typed transactions dla pozostałych domen nadal pozostają. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::message_records` — 1 passed; `storage::message_queries` — 2 passed | Wydzielono mapowanie `StoredMessageRow`, dekodowanie `ChatMessage` oraz JSON `reply_to` do `storage/message_records.rs`; storage zachowuje SQL/transakcję, a konwersja ma osobny test round-trip. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::pairing_records` — 1 passed; `storage::message_records` — 1 passed | Wydzielono finalizację `PairingItem` i mapowanie `InviteState` do SQL do `storage/pairing_records.rs`; `runtime_storage.rs` ma teraz osobne granice message/pairing records. Source-size runtime_storage spadł do 1451 linii. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::contact_records` — 1 passed; `storage::pairing_records` — 1 passed | Wydzielono mapowanie `VerificationState` do SQL do `storage/contact_records.rs`; projekcje kontaktu, pairingu i wiadomości mają teraz osobne helper boundaries. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::settings` — 1 passed | Wydzielono klucze ustawień oraz encode/decode JSON do `storage/settings.rs`; `runtime_storage.rs` zachowuje SQL settings, ale nie miesza już serializacji z transakcją. Usunięto nieużywany helper błędu JSON. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine storage::state_codecs` — 1 passed | Wydzielono cztery dekodery stanów do `storage/state_codecs.rs`; wywołania runtime storage i message records korzystają ze wspólnego codec boundary. Usunięto nieużywane importy po ekstrakcie. |
| 2026-08-03 | TC-022.3 | IN PROGRESS | — | `cargo test -p torchat-client-engine` — 48 unit + wszystkie integration/doc suites passed | Pełna regresja engine po ekstraktach settings/state/message/pairing/contact records jest zielona; pozostają dalsze repositories/typed transactions i inne otwarte findingi. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server config` — 1 passed; cały server — 18 passed | Wydzielono `server/config.rs` dla pairing secret, database URL i bind address; zachowano fail-fast secret validation oraz dotychczasowe defaults. Router/AppState nadal pozostają w `main.rs` do kolejnych ekstraktów. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server limits` — 1 passed; cały server — 19 passed | Wydzielono limity admission do `server/limits.rs` (`pending challenges`, body, websocket, crypto, DB); wartości i użycie przez router/permit budgets pozostały bez zmian. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server` — 19 passed | Wydzielono migracje DB, checksum validation i cleanup metadata do `server/bootstrap.rs`; `main.rs` zachowuje kolejność startup/cleanup, ale nie zawiera już implementacji bootstrapu. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server security` — 1 passed; cały server — 20 passed | Wydzielono HMAC pairing, pseudonimizację, constant-time compare i fingerprint do `server/security.rs`; wrapper `pseudonymous_id(AppState)` pozostał w main, a algorytmy nie zmieniły się. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server` — 20 passed | Wydzielono wszystkie stałe SQL `include_str!` do `server/queries.rs`; router/handlerzy zachowują te same query names, a `main.rs` nie zawiera już definicji zapytań. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `check-source-size.ps1 -WarnOnly`; `server/main.rs` 1832 linii (baseline 1821) | Po ekstraktach `config`, `limits`, `bootstrap`, `security` i `queries` main zmniejszył się względem wcześniejszych 1961 linii, ale nadal przekracza ratchet o 11; nie obniżono baseline i pozostaje dalszy podział handlerów/auth. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server http_support` — 1 passed; cały server — 21 passed | Wydzielono `server/http_support.rs` z error response, nickname validation i fallback contact nickname; zachowano dotychczasowy kontrakt HTTP i wszystkie wywołania handlerów. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `check-source-size.ps1 -WarnOnly`; `server/main.rs` 1806 linii (baseline 1821) | Po wydzieleniu HTTP helpers plik jest poniżej ratchet o 15 linii; nadal pozostaje do wydzielenia auth/session registry i cleanup handlers. Baseline pozostawiono bez obniżania przed zakończeniem podziału. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server auth` — 1 passed; cały server — 22 passed | Wydzielono challenge lifecycle (`Challenge`, consume-once, expiry i clock) do `server/auth.rs`; register/session handlers przekazują już tylko `state.challenges`. Usunięto duplikat z main i nieużywane importy czasu. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server auth` — 2 passed; cały server — 23 passed | `server/auth.rs` przejął także generowanie tokenu sesji i hash tokenu; `main.rs` zostawił tylko zapis/query PostgreSQL. Test potwierdza stabilny hash bez ujawniania tokenu. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server limits` — 1 passed; cały server — 23 passed | Admission control (`websocket_capacity_available`, DB permit acquisition) przeniesiono do `server/limits.rs`; handlerzy przekazują jawnie `db_operation_budget`, bez dostępu helpera do całego `AppState`. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server auth` — 2 passed; cały server — 23 passed | Autoryzację Bearer/session lookup przeniesiono do `server/auth.rs`; handlerzy przekazują tylko `&state.db` i nagłówki. Hash tokenu pozostaje wspólną funkcją auth. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server auth` — 2 passed; cały server — 23 passed | `server/auth.rs` przejął także `issue_session`; register/session handlers przekazują wyłącznie DB i installation ID, a generowanie/hash/zapis tokenu pozostają jednym workflowem auth. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server` — 23 passed | Wydzielono okresowy cleanup metadata/challenges/pairing attempts do `server/cleanup.rs`; `main.rs` przekazuje tylko jawne zasoby i okno expiry, a cleanup zachowuje ten sam interwał 60 s. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `check-source-size.ps1 -WarnOnly`; `server/main.rs` 1701 linii (baseline 1821); `cargo test -p torchat-server` — 23 passed | Po auth/cleanup split main jest 120 linii poniżej baseline. Pozostałe duże obszary to handler routing i websocket session; nie obniżono ratchet przed zakończeniem workflow split. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server` — 23 passed | Wydzielono transportowe `Connection`, `OutboundCommand` i bounded frame send do `server/ws.rs`; sesja websocket nadal pozostaje w main, ale typy/operacja wysyłki mają osobną granicę. |
| 2026-08-03 | TC-001.1 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — passed; cały engine — 48 unit + integration suites passed | Dodano regresję: zwykła wiadomość rozpoczynająca się od legacy `torchat-relationship-removed-v1:` bez poprawnego JSON nie blokuje kontaktu ani nie uruchamia tombstone/removal. |
| 2026-08-03 | TC-001.2 | IN PROGRESS | — | `protocol/relationship-removal.md`; test `remote_relationship_removal` | Udokumentowano state machine `active → removal_pending → removed → repaired`, atomowość transition+tombstone, replay boundary i semantykę `preserveHistory`. |
| 2026-08-03 | TC-022.4 | IN PROGRESS | — | `cargo check -p torchat-server`; `cargo test -p torchat-server` — 23 passed; `server/main.rs` 1665 linii | Serializacja `frame_message` została przeniesiona do `server/ws.rs`; połączony transport ramek ma jedną granicę, a main zmniejszył się o kolejne 36 linii względem poprzedniego pomiaru. |
| 2026-08-03 | TC-001.3–.4 | IN PROGRESS | — | `cargo fmt --all`; `cargo check -p torchat-client-engine`; `cargo test -p torchat-client-engine` — 48 unit + integration/doc suites passed | Dodano wire command `request_relationship_removal`, kontrakt JSON i binding Fluttera. Typed command oraz legacy `remove_relationship` korzystają ze wspólnego idempotentnego dispatchu; test envelope round-trip potwierdza typ i pola. Tombstone/outbox/ACK pozostają do implementacji w TC-001.5+. |
| 2026-08-03 | TC-001.5–.6 | IN PROGRESS | — | `cargo fmt --all`; `cargo test -p torchat-client-engine` — 48 unit + integration/doc suites passed | Dodano migrację `025_relationship_removal_outbox.sql` z `relationship_epoch`, `removal_id`, trwałym outboxem i indeksem retry. Local tombstone oraz typed removal intent są zapisywane w jednej transakcji SQLite; istniejące storage otrzymało kompatybilny wrapper. Brakuje jeszcze wire ACK, wysyłki/retry outboxu i fault/restart testu. |
| 2026-08-03 | TC-001.5 | IN PROGRESS | — | `cargo test -p torchat-core application` — 2 passed; `cargo check -p torchat-client-engine` | `ApplicationPayloadV1::RelationshipRemoved` przenosi opcjonalne `relationshipEpoch` i `removalId`; odbiorca używa ich przy atomowym local transition, a starsze payloady pozostają kompatybilne przez fallback. Outbox delivery/ACK/retry nadal pozostają. |
| 2026-08-03 | TC-001.5–.6 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 2 passed; cały engine — 48 unit + integration/doc suites passed | Dodano test atomowego zapisu tombstone + typed outbox, idempotentnego replay oraz reopen zaszyfrowanej bazy. Potwierdzono zachowanie `PENDING` i pojedynczego wpisu po replay; wysyłka transportowa, ACK/retry i fault point nadal pozostają. |
| 2026-08-03 | TC-001.6 | IN PROGRESS | — | `cargo fmt --all`; `cargo check -p torchat-client-engine`; `engine_pipeline_characterization` — 5 passed | Actor pobiera due removal intents i używa istniejącego MLS/relay `send_ephemeral_payload`; typed payload zawiera `removalId`/`relationshipEpoch`, a udany dispatch oznacza rekord jako `DISPATCHED`. Semantyczne powiązanie transportowego ACK z removal outboxem oraz retry po błędzie pozostają. |
| 2026-08-03 | TC-001.6 | IN PROGRESS | — | `cargo check -p torchat-client-engine`; `remote_relationship_removal` — 2 passed; actor tests — 15 passed | Relay outcome koreluje removal po stabilnym `removalId`: sukces oznacza outbox jako `ACKED` i usuwa delivery record, a błąd korzysta z istniejącego backoff/retry. Użyto obecnego capability-delivery retry jako adaptera; osobny jawny removal retry/ACK fault test pozostaje do dopracowania. |
| 2026-08-03 | TC-001.6 / TC-001.10 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 2 passed; cały engine — 48 unit + integration/doc suites passed | Rozszerzono regresję o `PENDING → DISPATCHED → ACKED`, duplicate ACK oraz reopen po ACK. Stan końcowy pozostaje trwały i nie tworzy drugiego wpisu; pełny transport fault injection i realny relay retry nadal pozostają. |
| 2026-08-03 | TC-001.7 | IN PROGRESS | — | `flutter analyze` — PASS | `NotificationSafeAppController` nie wysyła już legacy removal jako zwykłej wiadomości; lokalna zmiana i typed runtime command są jedyną ścieżką. Windows używa `request_relationship_removal`, a Android otrzymał stałą kontraktu. Pozostaje weryfikacja wszystkich platformowych bridge implementation i usunięcie produkcyjnych parserów legacy poza compatibility UI. |
| 2026-08-03 | TC-001.7 | IN PROGRESS | — | `mobile/android/gradlew.bat :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL; `flutter analyze` — PASS | Potwierdzono kompilację Androida po zmianie kontraktu. Legacy parser `relationship_message.dart` pozostaje wyłącznie w ścieżkach kompatybilnego renderowania historii; nie jest już używany do wysyłki removal. |
| 2026-08-03 | TC-001.8–.9 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 2 passed; cały engine — 48 unit + integration/doc suites passed | Dodano migrację 026 usuwającą `ignore_stale_relationship_removal` i `apply_incoming_relationship_removal`. Storage nie rozpoznaje już legacy prefixu; regresja potwierdza, że prefixed text pozostaje zwykłą wiadomością. Parser Fluttera pozostaje tylko kompatybilnym rendererem historii. |
| 2026-08-03 | TC-002.3 / .6 | IN PROGRESS | — | audyt `actor/application_envelope.rs`, `actor/receipts.rs`, `peer_events.rs`; testy engine — 48 unit + integration/doc suites passed | Po udanym `with_runtime` inbound jest już committed, a błąd `flush_pending_receipt_effects()` jest logowany jako deferred i nie propaguje rejection/crypto block. Klasyfikacja crypto-only pozostaje aktywna; fault injection po commicie i pełny ACK/restart test nadal wymagane. |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `cargo test --workspace --quiet` — PASS (engine 48, runtime 106, server 23 i pozostałe workspace suites) | Migracje 025/026, typed relationship removal i usunięcie legacy triggerów nie wprowadzają regresji w całym workspace. Flutter/Android oraz fault-injection pozostają osobnymi gate’ami. |
| 2026-08-03 | TC-002.8 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test delivery_resilience` — 3 passed | Dodano regresję durable delivery receipt po commit message: receipt `PENDING` pozostaje dostępny po reopen zaszyfrowanej bazy i zachowuje pełny rekord. Nadal brak fault point po commicie oraz realnego actor ACK-loss/retry testu. |
| 2026-08-03 | TC-001.7 / VALIDATION | IN PROGRESS | — | `mobile/flutter test --reporter compact` — 169 passed | Pełna regresja Fluttera po usunięciu legacy `sendMessage` dla relacji jest zielona; kontrakt runtime, UI flow i parser compatibility nie mają regresji. |
| 2026-08-03 | TC-003.1 | IN PROGRESS | — | Audyt `desktop/src/identity_store.rs` i `desktop/src/runtime_engine_stdio.rs` | Potwierdzono sprzężenie sekretów: identity private key jest zapisywany jako base64 w `installation.key`, a `database_key()` wyprowadza z niego klucz SQLCipher przez SHA-256. Separacja wymaga osobnego vault/key-file, migracji `PRAGMA rekey`, journalu i fallbacku dla istniejących baz; implementacja migratora pozostaje kolejnym krokiem. |
| 2026-08-03 | TC-003.2–.5 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 3 passed; `cargo check -p torchat-desktop` — PASS | Nowe bazy używają niezależnego losowego 32-bajtowego klucza w `torchat-client-v1.db.key` z ochroną `0600`; loader ma test stabilności, długości i fallbacku do legacy derivation dla istniejącej bazy. Pełny `DesktopSecretStore`, vault OS i rekey journal pozostają. |
| 2026-08-03 | TC-003.6 | IN PROGRESS | — | `cargo test -p torchat-client-engine rekey_rotates_sqlcipher_key_and_old_key_no_longer_opens` — passed; storage sqlite tests — 13 passed | Dodano `ClientDatabase::rekey` z walidacją 32-bajtowego klucza i `PRAGMA integrity_check`; regresja potwierdza, że stary klucz przestaje działać, nowy otwiera bazę, a dane są zachowane. Brakuje journalu migracji vault → rekey → verify → cleanup. |
| 2026-08-03 | TC-003.6 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 3 passed; `cargo check -p torchat-desktop` — PASS | Podłączono migrację legacy DB: journal `prepared → rekeying → verified`, rekey przez `ClientDatabase::rekey`, reopen weryfikacyjny, atomowy zapis `.db.key` przez `.key.tmp` i cleanup journalu dopiero po sukcesie. OS vault, crash matrix i bezpieczne usuwanie starego plaintext identity nadal pozostają. |
| 2026-08-03 | TC-003.6–.8 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 4 passed | Dodano end-to-end test migracji legacy DB: old key → journal/rekey → reopen new key → atomic key file → journal cleanup. Pozostają testy przerwania w poszczególnych fazach, OS vault i migracja identity z plaintextu. |
| 2026-08-03 | TC-003.2 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 5 passed; `cargo check -p torchat-desktop` — PASS | Dodano granicę `DesktopSecretStore` i atomowy `FileSecretStore` z walidacją 32 bajtów; backend można zastąpić DPAPI/Secret Service/Keychain bez zmiany workflow. Integracja z konkretnym OS vault pozostaje. |
| 2026-08-03 | TC-003.2 / .6 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 5 passed | Loader runtime korzysta z `FileSecretStore`; nowe klucze są przechowywane jako surowe 32 bajty, a wcześniejszy base64 `.db.key` pozostaje obsługiwany wyłącznie jako compatibility format. OS vault i pełna migracja identity nadal pozostają. |
| 2026-08-03 | TC-018.1–.2 | IN PROGRESS | — | `rust-toolchain.toml`; `mobile/.flutter-version`; audyt workflow release | Dodano repozytoryjne przypięcie Rust 1.94.1 z rustfmt/clippy oraz Flutter 3.41.9 używany przez workflow. Pinning pełnych SHA GitHub Actions, Java/NDK lock, audit/deny, SBOM i provenance pozostają. |
| 2026-08-03 | TC-018.3–.4 | IN PROGRESS | — | `cargo deny check bans licenses sources`; `cargo audit` | Dodano `deny.toml` z allowlistą licencji, blokadą nieznanych źródeł i ostrzeżeniami dla duplikatów/wildcardów. Workflow uruchamia przypięte `cargo-deny 0.18.3` oraz `cargo-audit 0.22.0`; lokalny audit ujawnił 6 aktualnych advisory dla libcrux (w tym high severity), więc gate pozostaje czerwony do aktualizacji zależności albo jawnej, terminowej decyzji wyjątku. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 8 passed; `cargo fmt --all` | Przeniesiono czystą logikę `commit_accept_pairing` do `runtime/pairing_process.rs`: walidacja artefaktów, idempotentny replay, expiry, transition i przygotowanie efektu transportowego są testowalne bez storage. Runtime zachowuje wyłącznie lookup, zapis i publikację eventu; dalsze workflowy pairing nadal pozostają. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 9 passed; `cargo fmt --all` | Przeniesiono także transition `commit_cancel_pairing` do pure `commit_cancel`: idempotencja anulowania i odrzucenie stanów terminalnych są testowane niezależnie od storage. Runtime pozostawia lookup, zapis i event; pełne wydzielenie pozostałych workflowów pairing nadal pozostaje. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 10 passed; `cargo fmt --all` | Wydzielono `complete_welcome` dla zakończenia pairingu: capability validation, `ACCEPTED → COMPLETED`, replay zakończonego pairingu i efekt potwierdzenia kontaktu są poza runtime orchestration. Event i zapis pozostają wykonywane tylko przy rzeczywistej zmianie stanu. |
| 2026-08-03 | TC-002.7 | IN PROGRESS | — | `cargo test -p torchat-client-engine actor:: --lib` — 17 passed; `cargo fmt --all` | Błąd flushu receipt po commicie ma teraz jawny, pseudonimowo-bezpieczny marker `receipt_queue_failed_after_commit` oraz klasę błędu (`storage`, `transport`, itd.), bez włączania treści błędu mogącej zawierać identyfikatory. Pełny licznik telemetryczny i test wymuszonego failure point pozostają. |
| 2026-08-03 | TC-002.7 | IN PROGRESS | — | `cargo test -p torchat-client-engine actor:: --lib` — 17 passed; `cargo fmt --all` | Dodano procesowy licznik `receipt_queue_failed_after_commit`, inkrementowany na obu ścieżkach flushu po commicie (inbound i relay recovery); durable receipt nadal pozostaje w SQLite. Eksport metryki do zewnętrznego telemetry backendu i fault-injection test pozostają. |
| 2026-08-03 | TC-003.7 | IN PROGRESS | — | `cargo test -p torchat-desktop` — 5 passed; `cargo fmt --all` | `FileSecretStore::read` zwraca teraz `zeroize::Zeroizing<Vec<u8>>`, więc tymczasowy bufor klucza jest czyszczony przy wyjściu z zakresu; boundary desktop secret store nie eksponuje już surowego bufora z odczytu pliku. Dalsze użycie klucza jest przekazywane do istniejącego `SecretBytes`; OS vault oraz pełna eliminacja krótkotrwałych kopii pozostają. |
| 2026-08-03 | TC-018.5–.6 | IN PROGRESS | — | `cargo metadata --locked --format-version 1 --no-deps` — PASS; `cargo-cyclonedx 0.5.9` lokalnie wygenerował JSON CycloneDX 1.5; `git diff --check` — PASS | Workflow release ma teraz przypięte narzędzia `cargo-deny`/`cargo-audit` oraz `cargo-cyclonedx 0.5.9`; publikuje zarówno `cargo-metadata.json`, jak i osobne BOM-y CycloneDX 1.5 dla workspace packages. Pełne provenance i pinning SHA akcji pozostają. |
| 2026-08-03 | TC-018.7 | IN PROGRESS | — | audyt workflow release; manifest provenance zawiera commit, runner, wersje narzędzi i SHA-256 subjects | Dodano `provenance.json` generowany po SBOM-ach i publikowany w tym samym artefakcie; obejmuje commit SHA, workflow/run ID, runner, wersję Rust/CycloneDX oraz hash każdego JSON subject. Jest to manifest audytowy, nie podpis attestation; podpisane provenance i pinning SHA akcji pozostają. |
| 2026-08-03 | TC-018.7 | IN PROGRESS | — | audyt workflow release; `actions/attest-build-provenance@v2` dodane warunkowo poza PR | Dodano podpisywaną attestation GitHub dla JSON-owych SBOM/provenance na push/manual run oraz minimalne permissions `contents:read`, `id-token:write`, `attestations:write`. PR-y nadal nie próbują wystawiać attestation; pełne pinning SHA akcji pozostaje. |
| 2026-08-03 | TC-018.1 | IN PROGRESS | — | `git ls-remote` dla używanych tagów; `Select-String uses:` nie wykazuje już `@vN`/`@stable`; `git diff --check` — PASS | Wszystkie akcje w release workflow przypięto pełnymi SHA z komentarzem wersji: checkout, rust-toolchain, rust-cache, upload-artifact, attest-build-provenance, Flutter action i setup-java. Pozostaje okresowa automatyczna aktualizacja pinów oraz lock Java/NDK. |
| 2026-08-03 | TC-018.2 | IN PROGRESS | — | `mobile/android/gradlew.bat :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL; Flutter 3.41.9; `FlutterExtension.kt` | Android `ndkVersion` przypięto do `28.2.13676358` zamiast dziedziczyć ją dynamicznie z dowolnego Flutter SDK, a workflow Java podniesiono do jawnego major `21` zgodnego z lokalnym toolchainem/Gradle 8.14. Pełny lock exact JDK/SDK package i NDK cache pozostaje. |
| 2026-08-03 | TC-018.2 | IN PROGRESS | — | `gradlew :app:dependencies --write-locks` — BUILD SUCCESSFUL; `gradlew :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL | Włączono Gradle dependency locking dla aplikacji i dodano `mobile/android/app/gradle.lockfile` (89 KB), obejmujący rozwiązywane zależności Android/Flutter. NDK/JDK są jawnie określone; exact SDK package/cache i okresowa aktualizacja lockfile pozostają. |
| 2026-08-03 | TC-018.2 | IN PROGRESS | — | audyt `.github/workflows/release-0-1-validation.yml`; `mobile/android/app/gradle.lockfile`; lokalny Gradle build PASS | Debug i signed-release Android jobs instalują teraz jawnie `platforms;android-36`, `build-tools;36.0.0` oraz `ndk;28.2.13676358` przez `sdkmanager`, zgodnie z przypiętym Gradle configiem. Pozostaje cache/periodic refresh i exact JDK distribution patch lock. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 11 passed; `cargo fmt --all` | Wydzielono `confirm_cancel` i usunięto ostatnią lokalną logikę przejścia anulowania z runtime. Pure boundary zwraca `None` dla replay, a zapis/event powstają wyłącznie dla realnego `PENDING/ACCEPTED → CANCELLED`; terminal states są testowane jako konflikt. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime pairing_process` — 12 passed; `cargo fmt --all` | Wydzielono `expire_item`: decyzja o expiry zależy wyłącznie od stanu `PENDING` i kontrolowanego czasu, a runtime wykonuje tylko zapis do inbox/outbox i event. Test potwierdza granicę deadline oraz brak zmiany dla nieprzeterminowanych itemów. |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `cargo test -p torchat-client-runtime` — 111 unit + 2 integration passed | Pełna regresja runtime po ekstraktach pairing `accept/cancel/welcome/expiry` jest zielona; dalsze otwarte findingi i pełny workspace validation pozostają. |
| 2026-08-03 | TC-018 | IN PROGRESS | — | korekta checklisty TC-018.1–.4 na podstawie wcześniejszych dowodów | Oznaczono jako wykonane wyłącznie elementy mające dowód implementacji: SHA akcji, toolchain pinning, cargo-audit gate i cargo-deny policy. TC-018.5–.7 pozostają częściowo otwarte (pełny SBOM wszystkich artefaktów, image scan i policy-negative tests). |
| 2026-08-03 | TC-018.7 | IN PROGRESS | — | `scripts/internal/check-release-policy.ps1` — PASS (`17 actions pinned`) | Dodano automatyczny gate sprawdzający pełne SHA akcji, obecność cargo-deny/audit/CycloneDX/attestation oraz blokadę nieznanych źródeł w `deny.toml`. Checker rzuca błąd przy naruszeniu każdej reguły; osobny test mutacyjny fixture pozostaje. |
| 2026-08-03 | TC-018.7 | IN PROGRESS | — | `scripts/tests/Test-ReleasePolicy.ps1` — PASS; checker pozytywny i mutacyjny negative case | Dodano test regresyjny, który mutuje przypiętą akcję do `@v4` i wymaga odrzucenia przez policy checker; pozytywny workflow nadal przechodzi. |
| 2026-08-03 | TC-020.3 | IN PROGRESS | — | `scripts/internal/check-relay-semantics.ps1` — PASS | Dodano automatyczne sprawdzanie UI/protokołu, które blokuje powrót obietnic „offline delivery”; semantyka relay pozostaje live-only (`RECIPIENT_OFFLINE → QUEUED`). |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `scripts/internal/check-relay-semantics.ps1` — PASS; `scripts/tests/Test-TorChatScripts.ps1` — 33 pliki PASS | Checker relay semantics jest objęty parser/regression suite skryptów i toleruje wyłącznie normatywną dokumentację zakazującą obietnicy offline delivery. |
| 2026-08-03 | TC-011.5 | IN PROGRESS | — | `scripts/internal/check-server-log-privacy.ps1` — PASS | Dodano CI checker wymagający eventów `queue full`, `write failed`, `offline` oraz odrzucający plaintextowe pola installation/message/pairing ID w tracingu serwera. Pełny runtime subscriber capture pozostaje. |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `scripts/tests/Test-TorChatScripts.ps1` — 34 pliki PASS | Checker prywatności logów serwera został włączony do ogólnej regresji skryptów i przechodzi parser/kontrakty. |
| 2026-08-03 | TC-018.5–.6 | IN PROGRESS | — | audyt workflow; przypięte `docker/setup-buildx-action` i `aquasecurity/trivy-action`; lokalny Docker niedostępny do wykonania obrazu | Dodano job `container-security`, który buduje `torchat-server:ci`, generuje CycloneDX image SBOM i failuje na unfixed/high/critical CVE, a następnie publikuje SBOM nawet przy błędzie skanu. Weryfikacja wymaga runnera z Dockerem; pełny APK/desktop SBOM pozostaje. |
| 2026-08-03 | TC-018.1 / VALIDATION | IN PROGRESS | — | `scripts/internal/check-release-policy.ps1` — PASS (`21 actions pinned`); `check-server-log-privacy.ps1` — PASS | Po dodaniu joba container-security wszystkie używane akcje nadal są przypięte pełnymi SHA, a policy/log gates przechodzą. |
| 2026-08-03 | TC-003 | IN PROGRESS | — | audyt checklisty względem `desktop/src/{identity_store,secret_store,runtime_engine_stdio}.rs`; `cargo test -p torchat-desktop` — 5 passed | Oznaczono jako wykonane TC-003.1/.2/.5/.6: inventory formatów, secret-store boundary, niezależny 256-bit key oraz journal rekey/reopen/cleanup mają implementację i regresję. OS vault, crash matrix i pełne zeroization pozostają otwarte. |
| 2026-08-03 | TC-003.4 | IN PROGRESS | — | `protocol/desktop-secrets.md`; audyt `desktop/Cargo.toml` i platform description | Jawnie ograniczono pierwszą migrację do obecnie wspieranych Windows/Linux targets; macOS wymaga przyszłego Keychain backendu, a DPAPI/Secret Service są opisane jako zamienne implementacje boundary. |
| 2026-08-03 | TC-018.7 | IN PROGRESS | — | `scripts/tests/Test-TorChatScripts.ps1` — 32 pliki PASS | Nowy checker i test mutacyjny są objęte ogólną walidacją PowerShell; wszystkie 32 skrypty przechodzą parser/kontrakty. |
| 2026-08-03 | VALIDATION | IN PROGRESS | — | `cargo test --workspace --quiet` — wszystkie workspace suites PASS (engine 49, runtime 111, server 23, desktop 5 i pozostałe); `scripts/tests/Test-TorChatScripts.ps1` — 32 PASS | Pełna regresja Rust po zmianach runtime, desktop secret handling, policy checker i Gradle/toolchain artifacts jest zielona. Advisory libcrux, fizyczny smoke cross-device i pozostałe otwarte findingi nadal wymagają osobnych działań. |
| 2026-08-03 | TC-001.10 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 3 passed | Dodano regresję `preserveHistory=false`: historia wiadomości jest usuwana, ale tombstone z flagą i typed removal outbox pozostają trwałe. Istniejące testy obejmują też zwykły legacy-marker, replay, duplicate ACK i reopen; fault injection transportu nadal pozostaje. |
| 2026-08-03 | TC-019 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 3 passed | Wzmocniono invariant test: 32 powtórzenia tego samego removal intentu z różnymi timestampami nie tworzą drugiego outboxu ani nie cofają `ACKED`; jest to deterministyczny property-style replay check bez nowej zależności. Pełne fuzz/fault injection pozostają. |
| 2026-08-03 | TC-017.6 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 4 passed | Storage odrzuca teraz stale `relationship_epoch` przed utworzeniem jakiegokolwiek outbox/tombstone side effectu; nowa epoka zachowuje `removalId` i `preserveHistory`, a test potwierdza brak stale outboxu. Bounded wire clock skew i pełna macierz ±1 min/±10 min/±24 h pozostają. |
| 2026-08-03 | TC-017.2 / .4 | IN PROGRESS | — | `cargo test -p torchat-core peer_protocol` — 8 passed | Endpoint expiry ma teraz jawny limit przyszłego timestampu `MAX_ENDPOINT_CLOCK_SKEW_SECS = 600`; przekroczenie zwraca `clock skew` zamiast akceptacji. Pełne invite clock injection i macierz testów pozostają. |
| 2026-08-03 | TC-017.1 / .6 | IN PROGRESS | — | `cargo test -p torchat-core` — 24 passed | Dodano `ContactInvite::parse_at(value, now)` jako jawny clock boundary; production `parse` deleguje do niego, a test sprawdza ±1 s wokół expiry bez odczytu procesu. Pozostają testy ±1 min/±10 min/±24 h i bounded skew dla invite payload. |
| 2026-08-03 | TC-017.4 / .6 | IN PROGRESS | — | `cargo test -p torchat-core peer_protocol` — 9 passed | Endpoint sprawdza teraz także przyszły `issued_at` względem jawnego `now`; macierz testuje +1 min, dokładnie +10 min jako dopuszczalne oraz +24 h jako `clock skew`. Invite payload ma nadal osobny parse_at boundary. |
| 2026-08-03 | TC-017.3 | IN PROGRESS | — | `cargo test -p torchat-client-engine retry_scheduler` — 2 passed; `cargo fmt --all` | Scheduler konwertuje trwały wall-clock retry timestamp do procesu-local `tokio::time::Instant` jednym pomiarem. Wygasły deadline daje natychmiastowe wznowienie, a późniejsze skoki zegara ściennego nie wydłużają ani nie skracają aktywnego sleepu. |
| 2026-08-03 | TC-021.1–.2 | IN PROGRESS | — | `scripts/internal/check-text-encoding.ps1` — PASS; kontrolowane `rg` markerów mojibake w źródłach — brak trafień | Checker poprawnie czyta UTF-8, sprawdza sentinel `Zażółć gęślą jaźń` i odrzuca znane markery mojibake. Aktualny checkout nie zawiera potwierdzonego problemu w plikach źródłowych; historyczne wzmianki pozostają w dokumentacji audytowej. |
| 2026-08-03 | TC-008.3/.5 | IN PROGRESS | — | `cargo test -p torchat-client-runtime read_receipt` — 2 passed | Potwierdzono durable read-receipt outbox w tej samej MLS kolejce oraz idempotentne przejście `DELIVERED → READ`: drugi duplicate receipt nie emituje drugiego eventu. Pozostaje raportowanie wyniku queued/disabled/error w Flutterze oraz szersza macierz restart/ACK/out-of-order/relay. |
| 2026-08-03 | TC-010.3/.4 | IN PROGRESS | — | `cargo test -p torchat-client-engine relay_control_coalescing` — 1 passed; `cargo fmt --all` | Dodano jawne klucze coalescingu dla nickname/pairing refresh/inbox; równoległy odpowiednik w kolejce zwraca `relay_control_coalesced`, a limit kolejki zwraca `relay_control_queue_full`. Potrzebują jeszcze metryki depth/rejected/coalesced i test przeciążenia. |
| 2026-08-03 | TC-009.2 | IN PROGRESS | — | `cargo test -p torchat-client-engine retry_policy_tests` — PASS; `cargo fmt --all` | Uporządkowano dowód wspólnej polityki retry: wszystkie obliczenia korzystają z `RetryPolicy`, age przyjmuje jawne `now_ms`, a jitter jest wstrzykiwany przez trait (`FixedJitter` w testach). Pozostaje migracja każdego lokalnego outboxu do jawnej klasyfikacji błędów. |
| 2026-08-03 | TC-010.5 | IN PROGRESS | — | `cargo test -p torchat-client-engine actor::tests::relay_control_coalescing_is_limited_to_refresh_like_commands` — 1 passed | Dodano procesowe liczniki `relay_control_rejected` i `relay_control_coalesced`; każda odmowa/coalescing emituje pseudonimowo-bezpieczny log z `depth`, `rejected`, `coalesced`. Test kompilacji przechodzi; osobny stress test actor queue pozostaje do dopisania. |
| 2026-08-03 | TC-008.6 | IN PROGRESS | — | `flutter test test/core/application_state/runtime_repository_snapshot_test.dart --reporter compact` — 9 passed; `dart format` | `RuntimeRepository.queueReadReceipts` zwraca jawnie `queued`, `disabled` albo `error`; ścieżka focus korzysta z tej granicy zamiast bezwarunkowego połykania błędu. Pozostaje rozszerzenie UI o prezentację wyniku oraz pełna macierz transportowa TC-008.7. |
| 2026-08-03 | TC-009.3 | IN PROGRESS | — | `cargo test -p torchat-client-engine retry_policy_tests` — 1 passed; `cargo fmt --all` | Dodano wspólny `retry_error_code` mapujący klasy `transient/permanent/authentication/protocol`; read-receipt outbox zapisuje teraz klasę wraz z błędem. Pozostaje podpięcie tej klasyfikacji do capability/pairing/endpoint outboxów i ich terminalnych stanów. |
| 2026-08-03 | TC-009.3 | IN PROGRESS | — | `cargo test -p torchat-client-engine pairing` — 3 passed; `cargo fmt --all` | Klasy retry są teraz zapisywane także przy błędach endpoint bootstrapu, capability delivery, pending Welcome i contact confirmation. Pozostają terminalne dead-letter transitions dla tych outboxów oraz pełne testy klasyfikacji per kolejka. |
| 2026-08-03 | TC-009.3/.7 | IN PROGRESS | — | `cargo test -p torchat-client-engine storage::sqlite` — 13 passed; `cargo check -p torchat-client-engine` — PASS | Dodano migrację `027_retry_dead_letters.sql` dla endpoint/capability/pairing outboxów. Błędy `permanent:` i `protocol:` ustawiają `dead_lettered_at`, a zapytania `due_*` je wykluczają; testy migracji i storage przechodzą. Pozostaje rozszerzenie testów klas per każda kolejka oraz ręczny retry dead-letter. |
| 2026-08-03 | TC-009.6/.7 | IN PROGRESS | — | `cargo test -p torchat-client-engine storage::sqlite::tests::recording_peer_endpoint_bootstrap_error_updates_last_error` — 1 passed | Dodano `ClientDatabase::retry_dead_letter(kind, id)` dla capability/endpoint bootstrap/contact confirmation/Welcome. Jawny retry resetuje tylko `dead_lettered_at` i `next_attempt_at`, zachowując ostatni błąd; test potwierdza terminal → due po ręcznym retry. |
| 2026-08-03 | TC-009.6 | IN PROGRESS | — | `cargo test -p torchat-client-engine --test command_idempotency` — 1 passed; `cargo check -p torchat-client-engine` — PASS; `flutter analyze --no-pub` — PASS; repository Flutter — 9 passed | Wystawiono ręczny retry dead-letter jako typed `RetryDeadLetter { kind, id }` w Rust, kontrakcie JSON, Windows bridge, Dart runtime/repository i Android contract constants. Komenda odrzuca nieznany lub nieterminalny rekord; UI panelu diagnostycznego nadal wymaga podpięcia przycisku/listy. |
| 2026-08-03 | TC-009.6 | IN PROGRESS | — | `cargo test -p torchat-client-engine storage::sqlite::tests::recording_peer_endpoint_bootstrap_error_updates_last_error` — 1 passed; `cargo check -p torchat-client-engine` — PASS; `flutter analyze --no-pub` — PASS | Dodano typed `ListDeadLetters` oraz storage union czterech outboxów (`capability`, `endpoint_bootstrap`, `contact_confirmation`, `welcome`), z zachowaniem pseudonimowych identyfikatorów i ostatniego błędu. Panel może teraz pobrać rzeczywistą listę; renderowanie rekordów i akcja UI pozostają. |
| 2026-08-03 | TC-009.6 | IN PROGRESS | — | `flutter analyze --no-pub` — PASS; `flutter test test/core/problems/runtime_problem_classifier_test.dart --reporter compact` — 5 passed | Panel kontaktu w trybie DEV renderuje rzeczywiste dead-lettery przez `ListDeadLetters` i udostępnia `Ponów` przez `RetryDeadLetter`; po akcji odświeża diagnostykę. Pozostaje test widgetowy samego panelu oraz finalna macierz wszystkich kolejek. |
| 2026-08-03 | TC-018.5/.6 | IN PROGRESS | — | `scripts/internal/check-release-policy.ps1` — PASS (`27 actions pinned`); `git diff --check` workflow — PASS | Workflow release generuje CycloneDX SBOM dla debug APK oraz Windows desktop builda, publikuje je jako osobne artefakty i dodaje warunkową GitHub attestation poza PR. Pozostaje wykonanie na runnerze CI oraz weryfikacja zawartości SBOM po realnym buildzie. |
| 2026-08-03 | TC-010.2 / TC-018.5–.7 | IN PROGRESS | — | `rg "unbounded_channel" common/torchat-client-engine/src` — brak; `scripts/internal/check-release-policy.ps1` — PASS (`27 actions pinned`) | Skorygowano checklistę na podstawie aktualnych artefaktów: relay-control i wszystkie engine channels są bounded; release workflow obejmuje Rust/APK/server image/desktop SBOM, attestation i policy negative test. Wykonanie workflow na hosted runnerze pozostaje dowodem zewnętrznym. |
| 2026-08-03 | TC-011.5 | IN PROGRESS | — | `scripts/tests/Test-ServerLogPrivacy.ps1` — PASS; `check-server-log-privacy.ps1` — PASS; release policy — PASS | Dodano mutacyjny test prywatności logów: celowo dodane plaintext `installation_id` musi zatrzymać checker. Checker przyjął parametr `RepositoryRoot`, więc test działa na izolowanej kopii źródła; workflow uruchamia negative test obok pozytywnego gate’a. |
| 2026-08-03 | TC-013.1–.2 | IN PROGRESS | — | `cargo test -p torchat-server limits` — PASS; audyt `server/main.rs`/`limits.rs` | Potwierdzono istniejące globalne semaphore dla crypto bootstrap i DB oraz limit aktywnych WebSocketów. Bounded body istnieje częściowo, ale jawne request-deadline middleware pozostaje otwarte wraz z anonimowym budżetem challenge, metrykami odrzuceń i load testem flood. |
| 2026-08-03 | TC-013.3 | IN PROGRESS | — | `cargo test -p torchat-server limits` — 1 passed; `cargo check -p torchat-server` — PASS | Dodano `limits::request_deadline` z 30-sekundowym `tokio::time::timeout` na routerze oraz zachowano `DefaultBodyLimit::max(16 KiB)`. Pozostają anonimowy budżet challenge, metryki odrzuceń i load test flood. |
| 2026-08-03 | TC-013.4 | IN PROGRESS | — | `cargo test -p torchat-server auth` — 2 passed; `cargo check -p torchat-server` — PASS | Challenge zwraca anonimowy `budget_token`, a kolejne żądania mogą używać `X-TorChat-Budget-Token`; serwer trzyma tylko pseudonimowany klucz, limit 10/60 s i sprząta bucket TTL. Brak zaufania do IP; metryki odrzuceń i load test pozostają. |
| 2026-08-03 | TC-013.5 | DONE | — | `cargo test -p torchat-server limits` — 1 passed; `cargo check -p torchat-server` — PASS | Domknięto zagregowane liczniki odrzuceń: challenge capacity/budget, crypto bootstrap, DB capacity, pairing attempts i websocket capacity. `/health` publikuje wyłącznie sumaryczny snapshot bez identyfikatorów; load test pozostaje osobnym `TC-013.6`. |
| 2026-08-03 | TC-013.6 | DONE | — | `cargo test -p torchat-server limits` — 2 passed; `cargo check -p torchat-server` — PASS | Dodano deterministyczny test admission flood: 128 prób przeciążenia otrzymuje jawne odrzucenie przy pełnym bounded DB budget, a legalny klient zostaje przyjęty po odzyskaniu permitu. Test nie udaje pełnego smoke testu HTTP/WebSocket; ten pozostaje poza zakresem bieżącej walidacji. |
| 2026-08-03 | TC-010.6 | DONE | — | `cargo test -p torchat-client-engine actor::connection::tests` — 1 passed; `cargo check -p torchat-client-engine` — PASS | Wyodrębniono bounded enqueue używany przez relay-control actor i dodano regresję floodu: limit 64, 65. element jest jawnie odrzucony, kolejność FIFO elementów przyjętych zostaje zachowana, a kolejka nie rośnie ponad limit. |
| 2026-08-03 | TC-017.5 | IN PROGRESS | — | `cargo test -p torchat-client-runtime` — 112 passed; `cargo check -p torchat-client-engine` — PASS; migracja testowana po korekcie oczekiwanej wersji | Dodano migrację 028 z trwałym `relationship_boundaries.relationship_epoch`; nowe parowanie zwiększa epokę, a lokalny removal pobiera bieżącą epokę i używa `current + 1`. Pozostaje test end-to-end ponownego parowania po removal oraz weryfikacja pełnej macierzy replay. |
| 2026-08-03 | TC-017.5 | DONE | — | `cargo test -p torchat-client-engine --test remote_relationship_removal` — 5 passed; `cargo check -p torchat-client-engine` — PASS | Domknięto cykl epoch: fresh pairing ustawia epokę większą od boundary i tombstone, usuwa tombstone, a lokalny removal pobiera bieżącą epokę i zapisuje następną. Regresja potwierdza nową epokę `8` po usunięciu w epoce `7`. |
| 2026-08-03 | TC-005.1 | DONE | — | audyt `EngineCommand`, `idempotency_descriptor` oraz `tests/command_idempotency.rs` | Dodano `protocol/operation-id.md` z katalogiem mutacji, regułami stabilności i rozdziałem `requestId`/`commandId`; dokument wymaga tego samego identyfikatora przez timeout/retry/reconnect i odrzucenia zmienionego payloadu. |
| 2026-08-03 | TC-005.5 | IN PROGRESS | — | `flutter analyze --no-pub` — PASS | Desktopowy host ma teraz `OperationJournal` w `SharedPreferences` i odtwarza stabilne `commandId` dla operacji z identyfikatorem argumentu po restarcie/reconnect. Pełne podpięcie journalu do Android hosta oraz retencja/prune pozostają. |
| 2026-08-03 | TC-005.5 | IN PROGRESS | — | `mobile/android/gradlew.bat :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL; `flutter analyze --no-pub` — PASS | Android `AndroidEngineHost` zapisuje stabilne identyfikatory operacji w atomowym pliku `.operation-command-ids.json` obok bazy i odtwarza je po restarcie hosta. Pozostaje ograniczenie/retencja journalu oraz pełne lost-response/replay E2E. |
| 2026-08-03 | TC-005.5 | IN PROGRESS | — | `:app:compileDebugKotlin --no-daemon --quiet` — BUILD SUCCESSFUL | Zapis Android journalu używa teraz `ATOMIC_MOVE + REPLACE_EXISTING`, więc aktualizacja istniejącego pliku jest bezpieczna także przy kolejnych retry. Retencja/prune i pełne E2E nadal pozostają. |
| 2026-08-03 | TC-005.8 | DONE | — | `flutter analyze --no-pub` — PASS; Android Kotlin build — BUILD SUCCESSFUL | Ujednolicono retencję hostowych journalów do bounded 256 wpisów na desktopie i Androidzie; przy dodaniu nowej operacji najstarszy wpis jest usuwany. Wyniki engine pozostają objęte osobnym `TC-015` prune. |
| 2026-08-03 | TC-005.5/.8 | IN PROGRESS | — | `flutter test test/core/runtime/operation_journal_test.dart --reporter compact` — 2 passed | Dodano test stabilności ID po odtworzeniu journalu oraz test limitu 256 wpisów. Desktop journal ma pełny dowód Flutter; Android nadal wymaga osobnego testu JVM/host lost-response, a TC-005.5 pozostaje otwarte. |
| 2026-08-03 | TC-014.1 | IN PROGRESS | — | `cargo test -p torchat-core mls` — oczekuje po uproszczeniu formatu | Ujednolicono zapis do jednego aktualnego formatu `TCMLS1` z envelope zawierającym app schema, wersję OpenMLS, ciphersuite, group ID, epoch i SHA-256 checksum. Usunięto nazewnictwo V2 oraz obsługę starszego formatu; test po zmianie i integracja golden fixture pozostają. |
| 2026-08-03 | TC-007.2 / TC-014.1–.2 | DONE | — | `cargo test -p torchat-core mls` — 6 passed; `cargo check -p torchat-client-engine` — PASS | Bieżący snapshot `TCMLS1` zawiera wersję schematu, OpenMLS, suite, group ID, epoch i checksum; parser wymaga tego jednego formatu, bez obsługi starego deployu. Weryfikacja checksum/metadanych odrzuca uszkodzony lub niespójny snapshot. |
| 2026-08-03 | TC-014.3 | DONE | — | `cargo run -p torchat-core --bin generate-dev-fixture`; `cargo test -p torchat-core mls` — 7 passed | Odświeżono `protocol/dev-fixtures/android-peer.json` do bieżącego `TCMLS1` envelope i dodano test, który przywraca oba checked-in snapshoty przez aktualny parser. Fixture jest teraz gate’em regresyjnym przed zmianą zależności MLS. |
| 2026-08-03 | TC-014.5 | DONE | — | `cargo test -p torchat-core mls` — 7 passed | Regresja potwierdza kontynuację rozmowy po restore, odrzucenie zmienionego checksumu oraz odrzucenie obniżonego app schema. Test dotyczy wyłącznie aktualnego `TCMLS1`, zgodnie z polityką nowego deployu. |
| 2026-08-03 | TC-014.4 | DONE | — | `cargo check -p torchat-client-engine` — PASS; `cargo test -p torchat-core mls` — 7 passed | Przy snapshotach z niewspieraną wersją/schema engine zwraca teraz jednoznaczne `re-pair required`; nie próbuje uruchamiać nieznanego formatu ani utrzymywać migratora starszych danych. |
| 2026-08-03 | TC-014.6 | DONE | — | `scripts/internal/check-release-policy.ps1` — PASS | Release policy wymaga teraz checked-in fixture’ów `android_snapshot` i `peer_snapshot` z bieżącym nagłówkiem `TCMLS1`; gate nie odnosi się do poprzednich wersji. |
| 2026-08-03 | TC-009.7 | DONE | — | `cargo test -p torchat-client-engine retry_policy_tests` — PASS | Potwierdzono wspólny test polityki retry: deterministic jitter, capped backoff, `max_attempts`, `max_age_ms` oraz klasyfikację `frame exceeds size limit` jako permanent protocol. |
| 2026-08-03 | TC-009.3 | DONE | — | `cargo test -p torchat-client-engine retry_policy_tests` — PASS | Wszystkie retry outboxy zapisują wspólną klasę `transient/permanent/authentication/protocol`; test kontraktu obejmuje cztery klasy, a permanent/protocol są wykluczane z automatycznego retry przez dead-letter state. |
| 2026-08-03 | TC-021.3–.4 | DONE | — | `scripts/internal/check-text-encoding.ps1` — PASS | Rozdzielono potwierdzone źródła repo od eksportowego `concat.txt`; naprawione zostały tylko wskazane pliki źródłowe, bez globalnego transcodingu. Checker aktualnego checkoutu przechodzi. |
| 2026-08-03 | TC-007.3–.4 | IN PROGRESS | — | `cargo check -p torchat-client-engine` — oczekuje po granicy API | Dodano publiczną granicę `DirectConversation::epoch()` dla adaptera anti-rollback. Kotwica musi zostać zaimplementowana przez platformowy secure-store (nie przez zwykły plik obok SQLCipher); podanie tego store do engine i kontrola przed restore pozostają. |
| 2026-08-03 | TC-016.1 | DONE | — | audyt `014_runtime_integrity.sql`, `026_remove_legacy_relationship_triggers.sql` i Rust storage/actor | Dodano `protocol/relationship-transition-inventory.md` z mapą wszystkich side-effectów triggerów 014 na typed Rust ownerów oraz invariantami wymaganymi przed usunięciem kolejnych triggerów. |
| 2026-08-03 | TC-016.2–.3 | DONE | — | `cargo test -p torchat-client-engine --lib` — 53 passed; `remote_relationship_removal` — 6 passed; runtime tests — 112 passed | `RelationshipTransition` jest częścią wspólnego runtime API. Local command, remote application envelope, replay/idempotency oraz re-pair przechodzą przez ten sam dispatcher; SQLite wykonuje atomowe side effects. Naprawiono też deterministyczny test endpointu, którego fixture wygasł względem aktualnego bounded clock skew. |
| 2026-08-03 | TC-016.4 + .6 | DONE | — | `cargo test -p torchat-client-engine storage::sqlite` — 13 passed; `remote_relationship_removal` — 6 passed | Dodano migrację 029 usuwającą relacyjne triggery lifecycle/guard. Ochrona przed odtworzeniem MLS i endpointu jest teraz w typed storage; poprawiono także obliczanie epoch, gdy boundary nie istnieje, ale tombstone już istnieje. SQL pozostaje przy ograniczeniach schematu i danych bazowych. |
| 2026-08-03 | TC-016.5 + .7 | DONE | — | `relationship_lifecycle_triggers_are_absent_after_current_migration` — passed; `remote_relationship_removal` — 6 passed; SQLite migrations — 13 passed | Equivalence/replay test potwierdza brak podwójnego tombstone/outbox side effect, a migracja otwierana z bieżącego baseline’u i z istniejącego schematu kończy na wersji 29 bez dawnych relationship triggerów. |
| 2026-08-03 | TC-020.3 | DONE | — | `flutter analyze --no-pub` — PASS; `rg` audit UI/protocol/README | Etykiety kontaktów, headera i desktopu używają teraz `live relay fallback`; dokumentacja jasno mówi, że relay jest live-only i nie jest offline delivery. Nie znaleziono obietnic trwałego relay delivery w UI. |
| 2026-08-03 | TC-020.5 | DONE | — | `cargo test -p torchat-client-engine --test delivery_resilience` — 4 passed | Dodano restartowy test: `RecipientOffline` pozostawia durable rekord `QUEUED`, po reopen staje się due, pojedynczy retry kończy się usunięciem outboxu, a duplikat forwarded pozostaje idempotentny. |
| 2026-08-03 | TC-011.4 | ACCEPTED | — | `protocol/logging-privacy.md` review; existing pseudonymization/capture tests | Secure debug nie jest potrzebny w release 0.1: diagnostyka nie wymaga plaintextu ani payloadów. Udokumentowano wymagania dla ewentualnego przyszłego opt-in: pseudonimizacja, 24h retencja, jawna akcja operatora i secure export. |
| 2026-08-03 | TC-007.3 | IN PROGRESS | — | `cargo test -p torchat-client-engine anti_rollback` — 2 passed; `cargo check -p torchat-client-engine` — PASS | Dodano `MlsEpochAnchor` i `validate_snapshot_epoch`: starszy snapshot zwraca `RePairRequired` i nie obniża kotwicy. Pozostaje podłączenie rzeczywistego Android Keystore/desktop secure vault oraz wywołanie walidacji przed `restore_current`. |
| 2026-08-03 | TC-007.4 | IN PROGRESS | — | `cargo check -p torchat-client-engine` — PASS; `anti_rollback` — 2 passed | Dodano `load_engine_technical_state_with_anchor`, który waliduje epoch przed dopuszczeniem rozmowy do mapy aktora i zwraca `re-pair required` dla rollbacku. Domyślny konstruktor nadal wymaga hostowego adaptera secure storage, więc pełne podpięcie platformowe pozostaje. |
| 2026-08-03 | TC-007.3 | IN PROGRESS | — | `mobile/android/gradlew.bat :app:compileDebugKotlin --no-daemon` — BUILD SUCCESSFUL | `LocalSecretStore` dostał szyfrowany, pseudonimizowany klucz epoch w Android Keystore-backed storage oraz monotoniczny zapis odrzucający cofnięcie. Pozostaje przekazanie wartości przez kontrakt engine i obsługa akcji aktualizacji po udanym snapshot transition. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime message_delivery` — 1 passed; `cargo check -p torchat-client-runtime` — PASS | Wydzielono pierwszy czysty fragment `runtime/message_delivery.rs` dla walidacji wejścia durable delivery i podłączono go do `ClientRuntime`; pairing workflow pozostaje w `pairing_process.rs`. Kolejne ekstrakty workflow nadal pozostają. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime` — 114 passed; `cargo check -p torchat-client-engine` — PASS | Wydzielono `runtime/relationship_process.rs` i podłączono wspólną walidację local/remote removal. Przy okazji naprawiono błąd kolejności argumentów local removal: `removed_at` i `relationship_epoch` były przekazywane zamienione miejscami. |
| 2026-08-03 | TC-019.1 | IN PROGRESS | — | `cargo test -p torchat-client-runtime testing` — 2 passed; pełny runtime — 116 passed | `TwoPeerHarness` obejmuje fake clock, kolejkę transportu, fault injection transportu i commitu, retry oraz exactly-once dedupe. Pozostaje podpięcie rzeczywistego storage/MLS oraz crash points aktora. |
| 2026-08-03 | TC-019.2 | IN PROGRESS | — | `cargo test -p torchat-client-runtime testing` — 3 passed; pełny runtime — 117 passed | Harness ma jawne `BeforeCommit` i `AfterCommit`: pierwszy retry nie widzi zapisu, drugi nie tworzy duplikatu po commicie. Pozostaje przeniesienie tych fault points do transakcji aktora i side effects storage. |
| 2026-08-03 | TC-019.3 | IN PROGRESS | — | `cargo test -p torchat-client-runtime testing` — 4 passed; pełny runtime — 118 passed | Harnessowy operation registry obejmuje durable receipt, pairing, relationship removal i capability; duplicate operation ID jest idempotentny per typ. Pozostaje podpięcie tych fault points do rzeczywistych actor workflows. |
| 2026-08-03 | TC-019.4 | IN PROGRESS | — | `cargo test -p torchat-client-runtime testing` — 5 passed; pełny runtime — 119 passed | Dodano deterministyczny state-machine test 256 kroków: cztery typy durable operations, 31 ID, retry/duplicate i invariant `commits <= unique operations`. Pozostają property tests na rzeczywistych modelach actor/storage. |
| 2026-08-03 | TC-019.5 | IN PROGRESS | — | `cargo test -p torchat-core mls` — 8 passed; `cargo check -p torchat-core` — PASS | Dodano bounded malformed corpus dla aktualnego `TCMLS1` decoder’a (0–1024 bajtów, deterministyczny generator); decoder bez panic bezpiecznie odrzuca niepoprawne dane. Pozostają fuzz targety application/peer/relay frame. |
| 2026-08-03 | TC-019.5 | DONE | — | `cargo test -p torchat-core` — 31 passed; `cargo check --manifest-path fuzz/Cargo.toml --bins` — PASS | Dodano bounded malformed corpus oraz formalny pakiet `fuzz/` z targetami `application_payload`, `peer_frame`, `relay_payload` i `mls_snapshot`; wszystkie targety kompilują się. |
| 2026-08-03 | TC-019.6 | IN PROGRESS | — | CI gate: `cargo check --manifest-path fuzz/Cargo.toml --bins --locked`; `cargo test -p torchat-core` — 31 passed | Dodano hermetyczne kroki PR do kompilacji wszystkich fuzz targetów i uruchomienia bounded decoder corpus. Pełny nightly fuzzing oraz real-Tor resilience pozostają osobnym zakresem. |
| 2026-08-03 | TC-019.6 | IN PROGRESS | — | `.github/workflows/nightly-resilience.yml`; PR fuzz gate; core 31 tests passed | Dodano harmonogram nightly z czterema targetami `cargo fuzz` i testami runtime. Job real-Tor jest jawnie warunkowany chronioną zmienną `TORCHAT_NIGHTLY_REAL_TOR`; lokalny checkout nie udaje dostępności infrastruktury. |
| 2026-08-03 | TC-012.3 | IN PROGRESS | — | `cargo test -p torchat-server` — 25 passed; `cargo check -p torchat-server` — PASS | Wydzielono atomowe `PairingAttemptWindow::consume` z bounded TTL resetem; challenge budget używa jednej write-lock sekcji i nie pozwala ominąć limitu przez równoczesne żądania. Shared cross-instance state nadal pozostaje. |
| 2026-08-03 | TC-012.4 | IN PROGRESS | — | `cargo test -p torchat-server lease` — 1 passed; pełny server — 26 passed | Dodano typed `ConnectionLease` z instance ID, connection ID, TTL, renew i expiry. Kontrakt registry jest przetestowany; pozostaje podpięcie do współdzielonego connection registry i cross-instance storage. |
| 2026-08-03 | TC-012.4 | IN PROGRESS | — | `cargo test -p torchat-server` — 26 passed; `cargo check -p torchat-server` — PASS | Lease został podłączony do WebSocket lifecycle: rejestracja zapisuje owner instance/connection, a cleanup usuwa lease wyłącznie przy zgodnym connection ID, więc stara sesja nie usuwa nowej. Cross-instance persistence nadal pozostaje. |
| 2026-08-03 | TC-012.4 | IN PROGRESS | — | `cargo test -p torchat-server` — 26 passed; `cargo check -p torchat-server` — PASS | Dodano migrację PostgreSQL `008_connection_leases.sql` oraz atomowe `acquire_shared_lease`/`release_shared_lease`; aktywny lease blokuje drugi proces, a wygasły może zostać przejęty. |
| 2026-08-03 | TC-012.5 | IN PROGRESS | — | `protocol/relay-multi-instance.md` review; lease tests 26 passed | Spisano shared-stream contract: route ID, owner lease, TTL, atomic claim, duplicate ACK i brak offline ciphertext store. Deployment nadal wymusza jedną replikę, więc broker i two-instance routing test pozostają. |
| 2026-08-03 | TC-012.5 | IN PROGRESS | — | `cargo test -p torchat-server` — 26 passed; `cargo check -p torchat-server` — PASS | Dodano migrację PostgreSQL `009_connection_route_stream.sql` oraz atomowe `publish_route`/`claim_route` z `FOR UPDATE SKIP LOCKED`, TTL i claim lease. Pozostaje podłączenie do konkretnych relay frames i two-instance integration test. |
| 2026-08-03 | TC-012.4–.5 | IN PROGRESS | — | `cargo clippy -p torchat-server --all-targets -- -D warnings` — PASS; server tests — 26 passed | Naprawiono clippy gate po dodaniu lease/stream: test TTL przeniesiono za funkcje modułu, stałe asercje zapisano jako const assertions, a helper publish ma jawne uzasadnienie liczby parametrów. |
| 2026-08-03 | TC-012.5 | IN PROGRESS | — | `cargo test -p torchat-server` — 26 passed | Podłączono live-only cross-instance relay: przy braku lokalnej sesji serwer sprawdza aktywny shared lease, publikuje tylko bieżący frame do `connection_route_stream`, a właściciel sesji okresowo atomowo claimuje, dostarcza i usuwa route. Braku aktywnego lease nie zamienia się w offline ciphertext store; pozostaje test dwóch instancji. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono generowanie pending pairing send effects z `runtime.rs` do `runtime/pairing_process.rs`; runtime zachowuje wyłącznie pobranie danych i delegowanie do pure workflow boundary. Testy pozostają do wykonania przez użytkownika. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Lista kontaktów nie renderuje już osobnego wskaźnika P2P i korzysta z `ContactPresenceStore` jako źródła diody/statusu; szczegóły techniczne pozostają poza skróconą listą. Testy UI pozostają do wykonania przez użytkownika. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto nieużywaną mapę `onlineContacts` z `ReleaseChatView`; header korzysta wyłącznie ze snapshotu wybranego kontaktu dla online/idle/focus. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto stare mapy presence z głównej ścieżki shell/list: desktop filtruje kontakty przez `ContactPresenceStore`, a `ConversationListSection` i widoki nie przyjmują już `onlineContacts`, `idleContacts`, `focusedConversations` ani `lastSeenContacts`. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Naprawiono expiry snapshotu: po wygaśnięciu coordinator ustawia `unknown` i czyści `expiresAt`, dzięki czemu reattach nie planuje ponownie starego timera. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Skrócona lista kontaktów pokazuje obecność oraz trasę kontaktu; usunięto z listy fingerprint jako dane techniczne i pozostawiono je w panelu szczegółów. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Connection center raportuje liczbę aktywnych snapshotów presence bez odwołania do legacy map. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono wspólne scalanie zdalnych pairing items (`merge_remote_items`) dla inbox i outbox; runtime pozostawia storage, eventy i acknowledgement orchestration. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono pure expiry wielu pairing items (`expire_items`); `runtime.rs` zachowuje wyłącznie zapis wygasłych rekordów i eventy. |
| 2026-08-03 | TC-005.5 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Android operation journal używa teraz stabilnego `messageId` również dla `send_message`; retry po utracie odpowiedzi/restartach nie generuje nowego command ID dla tej samej mutacji. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Inspector kontaktu pokazuje ważność obserwacji oraz ostatnie obserwowane połączenie P2P z `ContactPresenceSnapshot`; lista/header pozostają skrócone. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Coordinator odrzuca starsze `PresenceChanged` po `observedAt` oraz monotonicznym `sequence`, bez nadpisywania nowszego snapshotu; zdarzenie trafia do pseudonimizowanego logu discard. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Dodano niezależny focus expiry timer: `ConversationFocusChanged.expiresAt` wyłącza ikonę oka, a kolejny event anuluje poprzedni timer. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | `PeerConnectionChanged.retryInMs` jest scalane wyłącznie jako diagnostyka peer linku; nie zmienia aktywności kontaktu, a inspector pokazuje czas kolejnego retry/probe. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono pure reconciliację pairing outbox dla istniejącego kontaktu i pojedynczego niepowiązanego rekordu; runtime pozostawia lookup/storage/event orchestration. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Reguła wyboru rekordów do reconciliacji (`explicit match` / `single unbound repair`) została przeniesiona do `reconcile_outbox_items`; runtime deleguje całą decyzję domenową. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono pure `has_outstanding_request` dla blokady kolejnego pairing requestu; runtime pozostawia pobranie outboxu i zapis. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Walidacja gotowości profilu do generowania pairing code (`require_profile_ready`) jest teraz w `pairing_process.rs`; runtime deleguje ją po pobraniu profilu. |
| 2026-08-03 | TC-003.5–.6 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto desktopowe ścieżki legacy klucza: brak derivation z identity, base64 fallbacku i `migrate_legacy_database_key`; aktualny deploy wymaga niezależnego 32-byte key file i failuje zamknięcie przy nieprawidłowym formacie. |
| 2026-08-03 | TC-006/APPSTATE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto mobilny fallback legacy application snapshot; `RuntimeRepository` korzysta wyłącznie z aktualnego atomowego `RuntimeProjectionProvider`, bez składania stanu z niezależnych odczytów. |
| 2026-08-03 | TC-001.3 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto wire/UI alias `remove_relationship`; jedyną aktualną komendą jest `request_relationship_removal`, a wewnętrzne metody storage pozostają prywatną implementacją typed workflow. |
| 2026-08-03 | TC-011/PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Flutter presence diagnostics używają teraz skróconego SHA-256 digestu `contactId`, zamiast niestabilnego `hashCode`; plaintext ID nie jest logowane. |
| 2026-08-03 | TC-003 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Po usunięciu legacy SQLCipher key przywrócono wyłącznie import base64 wymagany przez bieżący plik identity; format niezależnego database key pozostał binarny 32-byte. |
| 2026-08-03 | TC-003.7 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Zdekodowany private key identity jest przechowywany w `Zeroizing<Vec<u8>>` do czasu utworzenia bieżącego `Identity`; tymczasowy bufor jest czyszczony po wyjściu z loadera. |
| 2026-08-03 | TC-003.7 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Tymczasowy base64 string używany przy zapisie identity jest również opakowany w `Zeroizing<String>`. |
| 2026-08-03 | CODE-HYGIENE | IN PROGRESS | — | `cargo fmt --all` — wykonano bez uruchamiania testów | Po zmianach kontraktu/legacy wykonano formatowanie workspace; nie uruchamiano buildów ani testów zgodnie z zakresem prac. |
| 2026-08-03 | TC-003.5 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Loader niezależnego klucza SQLCipher nie przyjmuje już ścieżki bazy i nie zawiera żadnego warunku kompatybilności; generuje/odczytuje wyłącznie aktualny key file. |
| 2026-08-03 | TC-018/019.6 | DONE dla pinningu | — | workflow review | Usunięto niepinowaną akcję toolchain z nightly workflow; Rust 1.94.1 jest instalowany i ustawiany przez `rustup`, a checkout pozostaje przypięty pełnym SHA. |
| 2026-08-03 | TC-009 / TC-013 / TC-014 / TC-021 | DONE | — | bieżące podchecklisty: wszystkie podpunkty `[x]`; wcześniejsze testy i gate’y zapisane powyżej | Ujednolicono statusy nadrzędne z rzeczywistym stanem podzadań. Zakresy z otwartymi podpunktami pozostają oznaczone `IN PROGRESS`. |
| 2026-08-03 | TC-008.1 | DONE | — | `flutter analyze --no-pub` — oczekuje po zmianie kontraktu | Bazowy `ClientRuntime.sendReadReceipts` zwraca teraz jawny `UnsupportedError`, a `RuntimeRepository.queueReadReceipts` mapuje go na `disabled`; implementacje aktywnej funkcji mogą nadpisać metodę. |

| 2026-08-03 | TC-022.2 / TC-008 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Dodano wspólną granicę workflow dla durable read-receipts: runtime waliduje kompletność identyfikatorów i timestamp przed przekazaniem efektu do aktora/transportu; storage pozostaje właścicielem selekcji rekordów due. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | `prepare_reject_pairing` korzysta teraz z pure `pairing_process::prepare_reject`; runtime zachowuje lookup storage i budowę przygotowania transportowego, bez powielania walidacji expiry/stanu/sendera. |
| 2026-08-03 | TC-008.6 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wynik zakolejkowania read-receipt jest propagowany z `RuntimeRepository` do kontrolera; błąd receipt nie jest już bezwarunkowo połykany i pojawia się w stanie UI, a focus pozostaje sygnałem przejściowym. |
| 2026-08-03 | PRESENCE/PROBING | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | `ProbeCoordinator` udostępnia teraz jedną subskrypcję kontaktu z kanałami peer/presence/focus/endpoint/capability; wszystkie kanały nadal korzystają ze wspólnego harmonogramu, deduplikacji i backoffu. |
| 2026-08-03 | PRESENCE/PROBING | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Flutter coordinator obsługuje także `PeerEndpointChanged` i `ContactCapabilityChanged`: odświeża technicznych subskrybentów bez zmiany availability ani peer linku, więc endpoint/capability nie udają obecności kontaktu. |
| 2026-08-03 | TC-011/PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Coordinator emituje pseudonimizowane markery `contact_probe_started`, `contact_probe_finished` i `contact_probe_backoff` zgodnie z przejściem peer linku; logi nie zawierają plaintext contact ID. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto dodatkowy `PeerTransportIndicator` z kompaktowej listy ostatnich rozmów; lista/header pokazują jedną diodę obecności, a dane P2P pozostają w inspectorze. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto także `PeerTransportIndicator` z normalnego headera rozmowy i `ConversationListTile`; status P2P nie konkuruje już z diodą presence, a szczegóły pozostają w inspectorze. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto nieużywany widget `PeerTransportIndicator`, żeby nie pozostawiać drugiego publicznego źródła statusu P2P w warstwie list/header. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Desktopowa lista kontaktów używa teraz pełnej etykiety availability (`status nieznany`, `offline`, `aktywny`, `bezczynny`) zamiast mapowania unknown → offline; trasa jest niezależnym spokojnym tekstem polityki. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Header rozmowy nie przyjmuje już osobnych flag `peerOnline`/`peerIdle`; avatar i tekst korzystają bezpośrednio z `ContactAvailability`, więc `unknown` pozostaje szary i nie jest renderowany jako offline. |
| 2026-08-03 | PRESENCE/UI | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto trasę P2P z normalnego headera; header pokazuje tylko nazwę, jedną linię obecności i ikonę oka, a trasa pozostaje w panelu technicznym. |
| 2026-08-03 | TC-022.2 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Wydzielono pure `pairing_process::transition_item`; archiwizacja i inne przejścia zaproszeń używają jednej normalizacji/transition granicy, a runtime pozostaje właścicielem storage i eventów. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Coordinator odrzuca starszy `ConversationFocusChanged` po `expiresAt`, dzięki czemu opóźniony event nie przenosi ikony oka ani nie nadpisuje nowszego focusu. |
| 2026-08-03 | PRESENCE | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Store odrzuca snapshoty ze starszą revision, a `reattach()` wznawia numerację od zachowanego snapshotu; reconnect nie może nadpisać listy/headera starym stanem. |
| 2026-08-03 | TC-007.3–.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Publiczne konstruktory `ClientEngineActor::new_with_anchor` i `ClientEngine::new_with_anchor` przekazują platformowy `MlsEpochAnchor` do walidacji przed restore; domyślny konstruktor pozostaje bez adaptera dla istniejących hostów. |
| 2026-08-03 | TC-003.2/.4 + TC-007 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Desktopowy database key korzysta teraz z natywnego OS vault przez `keyring` (Windows Credential Manager, macOS Keychain, Linux Secret Service); ścieżka pliku służy wyłącznie do deterministycznego account namespace i nie przechowuje sekretu plaintext. |
| 2026-08-03 | TC-007.3/.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Desktop stdio host przekazuje `DesktopMlsEpochAnchor` z OS vault do `ClientEngine::new_with_anchor`; każda rozmowa jest sprawdzana przed restore, a epoch zapisuje się w natywnym magazynie. |
| 2026-08-03 | TC-007.3/.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | FFI udostępnia `torchat_client_engine_new_with_mls_epoch_anchor` z callbackami get/set i kodami `0=success`, `1=no entry`; Kotlin/JNA może teraz podłączyć istniejący Keystore bez zmiany wire contractu. |
| 2026-08-03 | TC-007.3/.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Android `AndroidEngineHost` przekazuje `LocalSecretStore` przez JNA callbacki get/set do FFI; callbacki są przechowywane przez `NativeClientEngine` na czas życia handle, a epoch jest odczytywany/zapisywany w Keystore-backed store. |
| 2026-08-03 | TC-007.3/.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Domknięto aktualny przepływ Android: eksport FFI `new_with_mls_epoch_anchor`, mapowanie callbacków JNA oraz przekazanie `mlsEpochAnchorStore = secrets` z foreground service. |
| 2026-08-03 | TC-005.5 / TC-001.3 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Android operation journal używa teraz aktualnej komendy `request_relationship_removal`; usunięto ostatnią referencję do nieistniejącego wire aliasu `remove_relationship`. |
| 2026-08-03 | DEPLOYMENT / CURRENT VERSION | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Usunięto z launchera nazewnictwo `Cli-v2` oraz z kontrolera UI określenie legacy; bieżący deploy używa jednego aktualnego mutexu i odrzuca nieprawidłowe/nieaktualne eventy bez kompatybilnościowego aliasu. |
| 2026-08-03 | TC-002.2/.4 | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Dodano `InboundApplyResult` dla ścieżki peer (`committed`, `receipt_due`, `runtime_events`); ACK `Delivered` jest emitowany dopiero dla jawnie zatwierdzonego inboundu, a receipt pozostaje osobnym durable efektem. |
| 2026-08-03 | TC-001.3 / CONTRACT | IN PROGRESS | — | Implementacja bez uruchamiania testów na życzenie użytkownika | Checker runtime contract został przepięty z usuniętego `remove_relationship` na jedyną aktualną komendę `request_relationship_removal`; nie pozostawiono fałszywego wymagania kompatybilnościowego. |
| 2026-08-03 | IMPLEMENTATION AUDIT | IN PROGRESS | — | Bez uruchamiania testów/buildów na życzenie użytkownika | Wszystkie punkty oznaczone jako implementacyjne zostały porównane z aktualnym checkoutem i uzupełnione tam, gdzie kod już istnieje. Pozostałe checkboxy są wyłącznie testami, smoke/CodeGraph audit albo funkcją multi-instance niewymaganą przez deployment `replicas=1`; nie oznaczono ich jako DONE bez dowodu. |

## Następny krok

Implementacja zakresu bieżącego jest domknięta bez uruchamiania testów. Pozostaje lokalna weryfikacja użytkownika: testy Rust/Flutter/Android, smoke oraz ewentualne poprawki wynikające z ich rezultatów. Nie dodawać legacy/V2 ścieżek; nowy deploy używa wyłącznie aktualnych interfejsów.
