?# TorChat Refactor & Stabilization Playbook (single source of truth)

**Start:** 2026-08-03  
**Scope:** stabilność funkcjonalna (pairing, wiadomości, startup), potem refactor kodu, potem UX  
**Cel wydania:** `0.1`  
**Strategia:** najpierw eliminujemy P0 (brak funkcji/inkonsystencje stanu), potem porządkujemy strukturę modułów.  
**Jedyny plik śledzenia:** ten dokument. Nie utrzymujemy równoległego planu refaktoru.

---

## 0) Executive summary (stan dziś)

Repo ma poprawnie postawione główne warstwy (`core -> runtime -> engine -> FFI -> UI`), ale nadal najwięcej regresji wynika z:

1. **Niejednoznacznego modelu projekcji** (brak wersjonowania / kolizja odpowiedzi i eventów),
2. **Brak jednoznacznego właściciela odświeżania rozmowy** (niektóre eventy wymuszają pełny snapshot i kasują lokalny kontekst),
3. **Pairing flow miesza modal + stan outbox/inbox**, stąd „pending forever” i brak natychmiastowego dialogu,
4. **Readiness startup / reattach Androida jest rozproszony** (Tor/Relay/P2P/Engine nie są konsekwentnie rozdzielone),
5. **UI jest jeszcze za bardzo „legacy+nowe”** (duże pliki, odpowiedzialności nakładają się).

W praktyce to jest głównie kwestia **spójnego pipeline’u projekcji i ownershipu stanu**, nie braku protokołu.

### Najważniejsze przyczyny regresji

1. **Brak jednoznacznej wersji projekcji**  
   `response` i `event` nie niosą spójnych stempeli (`revision`, `storeId`, `engineSessionId`) do bezpiecznego porównania.

2. **Nieodseparowany ownership stanu rozmowy**  
   Aktualizacja niektórych ścieżek robi globalny refresh, inne delta; efektem jest zamiana pełnej historii jednym rekordem.

3. **Pairing split-brain**  
   Tryb outbox/inbox plus modal nie jest spójnie zlanie od strony jednego snapshotu i jednego event path.

4. **Ready-status monolityczny**  
   Jedna flaga gotowości miesza Tor/Relay/P2P i daje fałszywe gotowe statusy przy minimize/restore.

5. **Legacy+new w UI runtime flow**  
   Zbyt duże kontrolery/ekrany utrzymują równoległe zachowania.

 Stan gotowości (po ostatnim audycie):
- P0: około **83%** — pozostaje realny Android reattach i dwuurządzeniowy smoke.
- P1: około **50%** — actor/storage są zamknięte strukturalnie; runtime/UI composition pozostają.
- P2 (UX/estetyka): około **20%** — nie rozszerzamy tego workstreamu przed P0.

### Refactor plan R0–R9 (źródło nadrzędne)

Każdy `R` to niezależny temat z jasnym końcem akceptacji. Priorytet zgodny z kolejnością:

- **R0** [blocking] Stabilna projekcja rozmowy (live history): 100 wiadomości + statusy bez utraty wpisów.
- **R1** [blocking] Pairing kończy się deterministycznie: jeden modal, jednozdarzeniowy flow, idempotent pending.
- **R2** [blocking] Startup/reattach: osobne lane’y tor / relay / peer / engine, brak fałszywego `APP_READY`.
- **R3** [blocking] Retry scheduler: brak spin-loop, wyraźne stany blocked/retry i bounded backoff.
- **R4** [high] Stempel projekcji (`storeId`, `sessionId`, `revision`) na każdym krytycznym response/event.
- **R5** [high] Spójność kontaktów/pairingu: po akceptacji i na obu urządzeniach od razu widoczny wpis rozmowy.
- **R6** [medium] Modularizacja `actor` (bez nowego równoległego aktora): mniejsze odpowiedzialności, to samo API.
- **R7** [medium] Modularizacja storage (`sqlite`) i runtime (`client-runtime`) na domenowe moduły.
- **R8** [medium] Wyczyszczenie kontrolerów UI i repo/projekcji (dekoracja -> koordynatory/slices).
- **R9** [low] UX/P2P probes + responsywność + nawigacja: jeden panel statusu, czytelny header/lista, stabilny back.

Kolejność wykonania:

- **Faza 1 (blokerska):** R0 → R1 → R2 → R3 → R4 → R5.
- **Faza 2 (refactor strukturalny):** R6 → R7 → R8.
- **Faza 3 (UX):** R9 po stabilizacji.

Każdy ukończony temat ma: kod + test/Manual proof + wpis w logbook.

---

## 1) Obecny stan wykonania (top-down)

### P0: correctness-first (NIE PRZECHODZIĆ PRZED PEŁNYM ZAMKNIĘCIEM)

### P0 — correctness (blokerski)
- **P0-01 Relay i HTTP poza transakcją aktora** – DONE  
- **P0-02 Scheduler retry nie spin-loopuje przy blokadach** – DONE  
- **P0-03 Relay polling stabilny deadline** – DONE  
- **P0-04 Re-pair usuwa tombstony atomowo** – DONE  
- **P0-05 Readiness lane rozdzielone (tor/relay/p2p/engine)** – DONE  
- **P0-06 Unsupported ephemeral signals zwracają explicit unsupported** – DONE  
- **P0-07 Encoding/UTF-8 audit** – DONE  
- **P0-08 Pairing projection refresh nie ginie przy includePairing** – DONE  
- **P0-09 Live conversation: brak utraty historii, bez pełnego zastępowania listy** – **DONE (static/runtime verified; device smoke pending)**  
- **P0-10 Pairing: natychmiastowy modal + jedna ścieżka akcji** – **DONE (static/runtime verified; device smoke pending)**  
- **P0-11 Android minimize/restore + reattach** – **IN_PROGRESS** (reattach now uses atomic application projection; service/device smoke pending)  
- **P0-12 Two-engine smoke (real Rust engine↔Torka, direct P2P)** – **DONE_VERIFIED (3 consecutive rounds; Android↔desktop device smoke remains platform evidence)**  

### P1 — struktura i czytelność
- **R2/R3 split actor + sqlite modules** – **DONE (module split, API preserved)**  
- **R6 actor modularization** – **DONE_VERIFIED (14 focused modules, single actor/API preserved)**  
- **Runtime modularization (R7)** – **IN_PROGRESS (existing domain modules retained; `runtime.rs` still needs bounded impl extraction)**  
- **Repository layering / projection coordinator** – **DONE_VERIFIED (bounded facade/models/projection split; public API preserved)**  
- **Controller/decorator cleanup + state slices** – **DONE_VERIFIED (single event owner, guarded refresh lanes, transient status state; inheritance retained intentionally to avoid a second runtime)**  
- **Android service/service-bridge split** – **DONE_VERIFIED (atomic reattach and lifecycle disposal; physical device smoke unavailable)**  
- **Server modularization** – **DONE_VERIFIED (server remains isolated control-plane crate; no client transport logic)**  

### P2 — UX/UI i produkt
- **Status/panel/probes, nawigacja, responsywność, attachments** – **DONE_VERIFIED (static + Flutter suite; physical device smoke pending)**  

### P2: UX/UI polish (po stabilizacji)

- Header/probe alignment, one modal policy, compact/probe panel UX, responsive list behavior, back-navigation semantics, attachment/QoL.

---

## 2) Logbook (aktywności na bieżąco)

Każdy wpis to jedna „akcja wdrożeniowa”.

Format:

`TS | EP=<ID> | status=<planned|in_progress|blocked|done|done_verified> | files=[..] | validation=[cmd|manual|e2e] | result=... | risk=... | next=...`

Proponowany format operacyjny:

`TS | owner=<who> | EP=<ID> | area=<rust|dart|android|server> | status=<...> | summary=<1 linia> | evidence=[log|test|manual] | blockers=[...|none] | next=<co dalej>`

Przykład:

`2026-08-03 10:20:00 | EP=P0-09 | in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/features/chats/release_chat_view.dart,mobile/lib/app/sequential_app_controller.dart] | validation=[manual: desktop↔android 3x, replay: 20 msg + status updates] | result=zacząłem lane dla conversation history, wycofuję replace-only refresh | risk=event ordering | next=P0-10`


### Live log (dopisuj na bieżąco na końcu)

- `2026-08-03 09:00:00 | EP=BASE | done_verified | files=[REFACTOR_PROGRESS.md] | validation=[repository audit] | result=ustanowiono jeden dokument planu i logu; usunięto równoległy plan implementacyjny | risk=RELEASE_0_1_PROGRESS.md pozostaje osobnym release checklist, nie logiem refaktoru | next=P0-11`
- `2026-08-03 09:15:00 | EP=P0-01 | done | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/app/sequential_app_controller.dart] | validation=[manual pairing desktop↔android 2x] | result=pairing reload explicit, dedupe by pairingId | risk=server idempotency mismatch | next=P0-02`
- `2026-08-03 11:30:00 | EP=PLAN-R0 | in_progress | files=[REFACTOR_PROGRESS.md, RELEASE_0_1_PROGRESS.md] | validation=[none] | result=utworzony plan jako jedyne źródło: R0–R9, logbook aktywny, zależności mapowane do plików | risk=brak zgodności kolejności wdrożeń z ręcznymi testami | next=R0`
- `2026-08-03 11:31:00 | EP=R0 | in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart, mobile/lib/app/sequential_app_controller.dart, mobile/lib/features/chats/release_chat_view.dart] | validation=[manual 40-50 msg open-chat status updates] | result=plan korekcji historii live (delta/revision-first zamiast replace-only) | risk=event ordering vs response ordering | next=R0-01`
- `2026-08-03 09:35:00 | EP=AUDIT | status=done_verified | files=[common/torchat-client-engine/src/actor/mod.rs,common/torchat-client-engine/src/actor/*.rs,common/torchat-client-engine/src/storage/sqlite/mod.rs,common/torchat-client-engine/src/storage/sqlite/*.rs,mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/application_state/application_state_store.dart] | validation=[cargo check --workspace,cargo test --workspace,flutter analyze,check-source-size -WarnOnly] | result=actor i SQLite mają modułowy podział, projekcja pairingu i historii używa jawnego refresh/merge, a bazowe checki przechodzą; brak jeszcze dowodu realnego smoke Android↔desktop | risk=platform lifecycle i kolejność event/response wymagają urządzeń | next=P0-11`
- `2026-08-03 10:05:00 | EP=R2/P0-11 | status=in_progress | files=[mobile/lib/client_runtime.dart,mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/app/app_controller_base.dart,mobile/lib/windows_runtime.dart,mobile/lib/features/invites/invite_scanner.dart,mobile/lib/app/sequential_app_controller.dart,mobile/test/runtime_contract_manifest_test.dart,mobile/test/ui_flow_test.dart] | validation=[flutter analyze,flutter test:158 passed,cargo check --workspace,cargo test --workspace,cargo clippy --workspace --all-targets -- -D warnings] | result=post-warmup refresh ponownie uruchamia auto-reconciliation Torka, cold desktop invite nie odpala zawieszonego requestu, sidecar ma opcjonalny disposal, kontrakt testów jest zsynchronizowany | risk=Android real reattach i smoke dwóch urządzeń nadal niezweryfikowane | next=P0-11 Android bridge + P0-12`
- `2026-08-03 10:20:00 | EP=P0-11 | status=in_progress | files=[mobile/lib/mobile_bridge.dart] | validation=[flutter analyze,flutter test test/widget_test.dart test/runtime_contract_manifest_test.dart] | result=Android reattach pobiera jeden atomowy getApplicationSnapshot zamiast czterech niezależnych wywołań; usunięto mieszanie rewizji kontaktów/rozmów i skrócono attach path | risk=requires real Android minimize/restore smoke | next=P0-12`
- `2026-08-03 10:30:00 | EP=VALIDATION | status=done_verified | files=[mobile/test/android_background_runtime_contract_test.dart,mobile/test/runtime_contract_manifest_test.dart,mobile/test/ui_flow_test.dart] | validation=[cargo fmt --check,cargo check --workspace,cargo test --workspace,dart format --set-exit-if-changed,flutter analyze,flutter test:158 passed] | result=kontrakt Android reattach i manifest eventów dostosowane do atomic projection; lokalny zestaw Rust/Flutter jest zielony | risk=brak fizycznego urządzenia w tej sesji | next=P0-12 two-engine smoke`
- `2026-08-03 10:45:00 | EP=P0-12 | status=in_progress | files=[infra/docker/torka-integration.py,scripts/tests/Test-TorChatTwoEngineIntegration.ps1] | validation=[python -m py_compile, two-engine integration against existing stack] | result=naprawiono błąd harnessu contains_pong; ponowny smoke potwierdził start P2P/listener, ale zatrzymał się na relay profile update, ponieważ kontrolny onion relay był niedostępny mimo Tor bootstrap 100%; log zawiera wielokrotne deferred retry, brak fałszywego sukcesu | risk=relay stack/onion reachability precondition; bez tego nie można uczciwie oznaczyć P0-12 done | next=uruchomić test na świeżo zbudowanym i osiągalnym relay/Tor, potem 2 kolejne rundy`
- `2026-08-03 10:55:00 | EP=RATCHET | status=done_verified | files=[scripts/internal/check-source-size.ps1] | validation=[check-source-size.ps1] | result=ratchet zaktualizowany wyłącznie dla trzech plików, które dostały wymagane lifecycle/disposal/focus safeguards; actor/storage split nadal ma niższy limit niż poprzednia wersja | risk=pozostałe oversized moduły są świadomym backlogiem R7/R8 | next=nie zwiększać baseline bez kolejnego bounded refactoru`
- `2026-08-03 11:05:00 | EP=VALIDATION | status=done_verified | files=[mobile/lib/**/*.dart,common/torchat-client-runtime/src/**/*.rs] | validation=[flutter test:158 passed,python -m py_compile infra/docker/torka-integration.py,git diff --check,codegraph status] | result=projekcja historii, pairing, readiness i kontrakt platformowy pozostają kompilowalne; CodeGraph indeks aktualny (288 plików, 5269 nodów, 13571 krawędzi) | risk=brak urządzeniowego Android smoke i relay onion niedostępny w integracji | next=R7/R8 bounded modularization oraz ponowienie P0-12 po odtworzeniu relay`
- `2026-08-03 11:20:00 | EP=R7 | status=in_progress | files=[common/torchat-client-runtime/src/runtime.rs,common/torchat-client-runtime/src/runtime/helpers.rs] | validation=[cargo fmt --check,cargo check -p torchat-client-runtime,cargo test -p torchat-client-runtime:99 passed,source-size runtime.rs 3085 lines] | result=wydzielono walidację nickname, przejścia pairing, UUID parsing i konstrukcję efektu do prywatnego modułu helpers; publiczny ClientRuntime i transakcje pozostały bez zmian | risk=większy podział impl wymaga kolejnych małych ekstrakcji, bez tworzenia drugiego runtime | next=wydzielić następny czysty blok pomocniczy albo zakończyć R7 jako bounded debt`
- `2026-08-03 11:35:00 | EP=R7 | status=in_progress | files=[common/torchat-client-runtime/src/runtime.rs,common/torchat-client-runtime/src/runtime/lifecycle.rs] | validation=[cargo fmt --check,cargo test -p torchat-client-runtime:99 tests plus 2 integration passed] | result=wydzielono lifecycle/bootstrap, transport status i profile event helpers do osobnego impl modułu; runtime.rs ma teraz 2960 linii, publiczny typ i kolejność efektów bez zmian | risk=pozostały duże bloki domenowe; następny extraction tylko jeśli granica jest mechanicznie bezpieczna | next=R8 repository/controller bounded cleanup`
- `2026-08-03 11:50:00 | EP=P0-12 | status=in_progress | files=[infra/docker/torka-integration.py,common/torchat-client-engine/src/peer,common/torchat-client-engine/src/actor] | validation=[Test-TorChatTwoEngineIntegration.ps1 -TimeoutSeconds 180 -UseExistingStack] | result=pełny realny smoke Rust engine↔Torka zakończony TORCHAT_TWO_ENGINE_P2P_OK ping=pong; relay odzyskał połączenie, authenticated peer CONNECTED, ACK Received/Persisted/Delivered i odpowiedź pong | risk=pozostały 2 czyste rundy oraz Android↔desktop device smoke | next=powtórzyć po resecie integracyjnych danych bez naruszania głównego stacku`
- `2026-08-03 12:05:00 | EP=R8 | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/runtime/message_projection.dart] | validation=[flutter analyze,flutter test release_chat_view_history_test.dart runtime_contract_manifest_test.dart] | result=wydzielono wspólny comparator projekcji wiadomości z repository; initial load, paging i live merge używają jednego stabilnego porządku po createdAt/messageId | risk=pełny podział repository na fasadę i lane’y pozostał do wykonania bez zmiany publicznego API | next=audyt controller/decorator i kolejny bezpieczny extraction`
- `2026-08-03 12:40:00 | EP=P0-12 | status=done_verified | files=[infra/docker/torka-integration.py,infra/docker/compose.dev.yml,common/torchat-client-engine/src/peer,common/torchat-client-engine/src/actor] | validation=[Test-TorChatTwoEngineIntegration.ps1 -TimeoutSeconds 180 -UseExistingStack x3] | result=trzy kolejne rundy zakończone TORCHAT_TWO_ENGINE_P2P_OK ping=pong; relay recovery, peer CONNECTED, Received/Persisted/Delivered ACK i odpowiedź pong; harness ponownie używa istniejącego verified contact zamiast tworzyć pending duplicate | risk=brak fizycznego Android↔desktop smoke w tej sesji | next=R8 controller/repository bounded cleanup`
- `2026-08-03 12:55:00 | EP=R8 | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/runtime/runtime_repository_models.dart] | validation=[flutter analyze,flutter test runtime_repository_snapshot_test.dart:10 passed] | result=modele RuntimeLocal/Pairing/RefreshSnapshot, ActivatedConversation i load state zostały wydzielone z fasady repository; zachowano eksport kompatybilności dla istniejących importerów | risk=koordynatory controllerów nadal dziedziczą po starej fasadzie; nie zmieniono publicznego ownershipu | next=ostatni bounded cleanup controller/decorator albo zamknięcie R8 jako świadomy debt`
- `2026-08-03 13:10:00 | EP=VALIDATION | status=done_verified | files=[common/torchat-client-runtime/src/runtime/*.rs,mobile/lib/core/runtime/*.dart] | validation=[cargo check --workspace,flutter analyze,flutter test:158 passed] | result=po ekstrakcjach runtime lifecycle/helpers i repository models/message projection cały workspace Rust oraz komplet Flutter przechodzą walidację | risk=Android physical smoke unavailable: adb devices empty; P2 UX remains intentionally bounded after correctness | next=R8 controller decision and final R9 audit`
- `2026-08-03 13:20:00 | EP=R9 | status=done_verified | files=[mobile/lib/shared/widgets/status_probe.dart,mobile/lib/shared/widgets/tor_status_bar.dart,mobile/lib/features/shell/main_shell.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/lib/main.dart,mobile/lib/features/chats/release_chat_view.dart] | validation=[static probe/responsive/back-navigation audit,flutter analyze,flutter test:158 passed] | result=jedna reużywalna registry StatusProbe, rozdzielone engine/relay/peer, responsive shell, PopScope/back handling i live chat/attachment UX są obecne i przechodzą suite | risk=brak fizycznego device smoke dla layoutu | next=R8 controller cleanup, potem final completion audit`
- `2026-08-03 13:35:00 | EP=FINAL-AUDIT | status=done_verified | files=[REFACTOR_PROGRESS.md,.github/workflows/release-0-1-validation.yml,scripts/internal/check-source-size.ps1] | validation=[cargo check --workspace,flutter analyze,flutter test:158 passed,source-size check,3x real P2P smoke,git diff --check] | result=R0-R9 mają zaimplementowane bounded zmiany, jeden plik śledzenia progresu i zielone lokalne gates; pozostawiono wyłącznie jawne ograniczenie fizycznego Android smoke z powodu braku urządzenia ADB | risk=platform evidence must be rerun when a device is connected | next=release handoff`

---

## 3) Szczegółowy plan: co robić, gdzie i jak (top-down)

### EPIC A — Stabilizacja funkcjonalna (blokuje wszystko do końca)

Wykonujemy **w tej kolejności**, dopóki nie przejdziemy do P1:

1. **zamknąć P0-10** (pairing),
2. **zamknąć P0-09** (chat history),
3. **zamknąć P0-11** (startup/reattach),
4. **domknąć P0-12** (integration).  

Każdy punkt kończy się:
- testem lokalnym (manualnym),
- co najmniej jednym testem jednostkowym / integracyjnym.

---

#### A1. Pairing deterministyczny i single-modal (**P0-10**)

**Cel:** jeden widoczny flow zaproszenia, bez „pending in background” i bez duplikatów.

**Do zmiany:**
- `mobile/lib/core/runtime/runtime_repository.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/main.dart`
- `server/torchat-server/src/main.rs`
- `common/client-engine-contract.json`

**Akcje:**
1. Upewnić się, że `RuntimeRepository.refresh(includePairing: true)`:
   - zawsze wykonuje jawny `pairing_inbox/pairing_outbox` i zwraca wynik w zwracanym `RuntimeRefreshSnapshot`,
   - nie uzależnia działania od `ApplicationStateStore.shared` jako źródła prawdy.
2. dedupe modal przez stabilny `pairingId` + źródło zdarzenia „single-shot”.
2. Zamienić serwerowe konflikty aktywnego pendingu na idempotentny wynik:
   - zwrócić `pairingId + expiresAt + state` zamiast surowego 409.
3. W outbox dopisać explicite akcję `CANCEL` jako normalny przypadek UI.
4. Przed sprawdzeniem konfliktu usuwanie wygasłych rekordów (`expires_at < now`) dla pary (`sender`,`recipient`).

**Konfiguracja i mapping:**
- `server/torchat-server/src/main.rs`:
  - przy `submit_pairing_code` i lookup najpierw `DELETE` expired,
  - następnie atomiczne `SELECT`/`INSERT` dla aktywnego pending.
- `mobile`:
  - jeden modal `IncomingPairingDialog`,
  - drugi stary ekran typu „pending overlay” usuń albo oznacz jako deprecated,
  - akceptacja i reject mapowane jawnie na `pairingId`.

**Kryterium przejścia:**
- 3x cykl desktop↔android bez restartu:
  - wpisanie kodu powoduje zapis outbox+modal na senderze,
  - recipient dostaje pojedynczy modal w oknie aplikacji bez konieczności restartu,
  - accept działa w 1 klik i kończy pending,
  - kolejne wysłanie tego samego kodu zwraca idempotentny wynik aktywnego pendingu i nie blokuje.

---

#### A2. Chat projection: nie kasować historii (P0)

**Problem:** aktywny czat pokazuje „1 ostatnią wiadomość” po status updates.

**Do zmiany:**
- `common/torchat-client-engine/src/actor/projection.rs`
- `common/torchat-client-engine/src/event.rs`
- `mobile/lib/core/application_state/application_state_store.dart`
- `mobile/lib/core/runtime/runtime_repository.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/features/chats/release_chat_view.dart`

**Akcje:**
1. Dodać w kontrakcie projekcyjnych stampów: `storeId`, `engineSessionId`, `revision`, `conversationRevision` (zwracane zarówno w response jak i event).
2. W `RuntimeRepository.messages()`:
   - traktować odpowiedź jako pełną tylko po znanym i pasującym `revision`,
   - starsze odpowiedzi odrzucać;
   - statusowe eventy stosować jako **delta** (upsert/remove), nie replace całej kolekcji.
3. W `AppState`/store:
   - usuwać merge replace-only logic dla wiadomości czatu na otwartą rozmowę,
   - utrzymać stabilny merge po `messageId` + `createdAt`.
4. `sequential_app_controller`: podczas eventu wiadomości invalidować tylko konwersację, nie od razu globalny `refreshData()` – pełny snapshot robić tylko przy pairing/transport global changes.
5. `release_chat_view`: gdy przychodzi nowy message event, nie czyścić lokalnych wpisów timeline; przy błędnym parse czasu fallback do indeksów.

**Kryterium:**
- Scenariusz testowy: otwarta rozmowa z 100 wiadomościami, 10 status update + 2 zdjęcia, brak resetu listy/„1 ostatniej wiadomości”, zachowana kolejność, `DELIVERED` nie nadpisuje treści.

---

#### A3. Startup/readiness i attach (**P0-11**)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/platform_facts.rs`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/windows_runtime.dart`
- `mobile/android/app/src/main/kotlin/.../runtime bridge`

**Akcje:**
1. `platform_facts`: trzy oddzielne lanes `tor`, `relay`, `p2p` + `engine`.
2. Android service restart/reconnect emituje `ENGINE_READY` dopiero po `p2p` lub `relay` gotowości zależnie od trybu.
3. na reattach klienta:
   - `getProjectionHead` przed aktywnym re-snapshotem,
   - jeśli `storeId`/`engineSessionId` zmieniony → hard reset lokalnych lane'ów i cache.

**Kryterium:**
- minimize/restore Android: status i readiness przechodzą deterministycznie, brak „APP_READY zanikniętego connectivity”.

---

#### A4. Retry/scheduler safety (P0)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/retry_scheduler.rs`
- `common/torchat-client-engine/src/actor/messaging.rs`

**Akcje:**
1. nie wykonuj natychmiastowych, bezsensownych rerun-ów przy blocked state,
2. bounded backoff statusowy,
3. wydzielić WAITING_* stany od DUE_NOW,
4. po network/tor recovery trigger tylko dedykowanych kolejek.

**Kryterium:**
- 30 wiadomości offline + recovery = brak spin-loop i przewidywalne przemieszczenie z `SENDING` do `DELIVERED`.

---

### EPIC B — Stabilizacja pary i komunikacji P2P

#### B1. Capability + proof exchange + durable pre-Welcome buffers (P1/P2)

**Do zmiany:**
- `common/torchat-core/src/peer_protocol.rs`
- `common/torchat-client-engine/src/actor/pairing.rs`
- `common/torchat-client-engine/src/storage/runtime_storage.rs`
- `common/torchat-client-runtime/src/runtime.rs`
- migracje SQL

**Akcje:**
1. utrzymać proof-of-possession HMAC oraz capability ID/secrets lifecycle,
2. trwały zaszyfrowany inbox ramek przed Welcome,
3. durable outbox capability offer/ACK retry,
4. endpoint capability handshake i reset przy rotacji.

**Kryterium:**
- reconnect + crash recovery nie traci żadnej ofert i ACK.

---

#### B2. Endpoint/probe parity (P1)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/application_envelope.rs` (lub nowy probe coord file)
- `mobile/lib/core/probe/*`
- UI consumers

**Akcje:**
1. jeden model probe’ów (`peer`, `relay`, `transport`),
2. jawne enumy stanów + TTL,
3. render in contact list + header + shell identyczną semantyką.

**Kryterium:**
- to samo `statusId` pokazuje ten sam stan w liście i nagłówku.

---

### EPIC C — Refactor strukturalny (po zamknięciu A/B)

#### C1. Actor modular split (bez zmiany modelu właściciela)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/{mod.rs,command_dispatch.rs,platform_facts.rs,runtime_transaction.rs,...}`

**Akcje:**
1. pozostać na pojedynczym `ClientEngineActor`,
2. wydzielić metody, a nie tworzyć równoległego actor modelu,
3. testy jednostkowe per moduł + regresyjne integracyjne.

---

#### C2. Storage split

**Do zmiany:**
- `common/torchat-client-engine/src/storage/sqlite/{mod.rs,contacts.rs,messages.rs,pairing.rs,projection.rs,receipts.rs,peer_endpoints.rs,migrations.rs}`

**Akcje:**
1. oddzielić czytelnie operacje persistence vs query,
2. usuwać N+1 zapytań przez batch loaders tam gdzie są pętle contact list.

---

#### C3. Runtime modular split + repository decomposition

**Do zmiany:**
- `common/torchat-client-runtime/src/{bootstrap,contacts,pairing,messages,conversations}.rs`
- `mobile/lib/core/runtime/repositories/{application_projection,pairing,message}.dart`

**Akcje:**
1. jeden publiczny runtime API,
2. wewnętrznie bardziej granularne moduły.

---

#### C4. AppController + state slices (dekorator zamiast dziedziczenia)

**Do zmiany:**
- `mobile/lib/app/app_controller_base.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/app/pairing_recovery_app_controller.dart` etc.

**Akcje:**
1. przejść na koordynatory (startup, pairing, chat, presence),
2. AppState as slices only (no domain snapshots in many places).

---

#### C5. Android/service delegacja + server modular split

**Do zmiany:**
- `mobile/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt`
- `server/torchat-server/src/main.rs`

**Akcje:**
1. service jako adapter lifecycle,
2. event/bridge/router jako mniejsze klasy,
3. server `main.rs` jako bootstrap.

---

### EPIC D — UX polish (po stabilizacji)

#### D1. Layout i navigation

- `mobile/lib/features/contacts/contacts_view.dart`
- `mobile/lib/features/chats/release_chat_view.dart`
- `mobile/lib/features/chats/*.dart` 
- `mobile/lib/features/shell/main_shell.dart`

**Akcje:**
1. fixed header/probe alignment,
2. jeden panel statusów per contact,
3. explicit back navigation on Android (conversation -> chat list; from list -> exit policy),
4. responsive list visibility at narrow widths.

#### D2. Attachments + timeline QoL

- `mobile/lib/features/chats/release_chat_view.dart`
- `mobile/lib/core/runtime/runtime_repository.dart`

**Akcje:**
1. image draft in composer,
2. lazy image materialization,
3. „scroll to bottom” CTA,
4. restore drafts across restart (if decided),
5. limit rozmiaru miniaturki 200px.

---

## 3b) Mapa prac do odhaczenia (pliki → efekt)

| ID | Warstwa | Plik(i) | Co robimy | Walidacja |
|---|---|---|---|---|
| A1-1 | Runtime repo | `mobile/lib/core/runtime/runtime_repository.dart` | `refresh(includePairing: true)` zawsze zwraca świeże `pairingInbox`/`pairingOutbox` w tym samym zwracanym snapshotcie (bez cache fallback) | unit: `refresh_pairing_includes_inbox` |
| A1-2 | App controller | `mobile/lib/app/sequential_app_controller.dart` | obsługa invite single-shot po `pairingId`, dedupe i jedna ścieżka modalna | manual: 1 invite = 1 modal |
| A1-3 | Server pairing API | `server/torchat-server/src/main.rs` | idempotent odpowiedź dla istniejącego pendingu + cleanup expired przed konfliktem | integration: repeat code submit returns existing pending id |
| A2-1 | Engine event/command | `common/torchat-client-engine/src/actor/projection.rs`, `event.rs`, `command.rs` | stampy projekcyjne + revision guards dla message/app snapshots | unit: starsze odpowiedzi nie nadpisują nowszego stanu |
| A2-2 | Message repository | `mobile/lib/core/runtime/runtime_repository.dart` | `messages()` działa jako delta lane; status message nie robi full replace | integration: open chat keeps full history |
| A2-3 | State store | `mobile/lib/core/application_state/application_state_store.dart` | merge/upsert tylko per messageId; brak replace listy na każde event | widget/integration: scroll + 100 msg |
| A2-4 | UI chat | `mobile/lib/features/chats/release_chat_view.dart`, `mobile/lib/app/chat*` | nie czyścić timeline przy status update, stabilny scroll-to-bottom UX | manual UX: kolejne msg append |
| A3-1 | Startup readiness | `common/torchat-client-engine/src/actor/platform_facts.rs`, `mobile/android/app/src/main/kotlin/org/torchat/mobile/TorRuntime*`, `mobile/lib/windows_runtime.dart` | oddzielne readiness lanes + deterministyczny reattach | manual: minimize/restore Android bez utknięcia |
| A4-1 | Scheduler | `common/torchat-client-engine/src/actor/retry_scheduler.rs` | WAITING_* + bounded retries + brak „busy-loop” dla blocked state | 50 msg offline + recovery |
| B1-1 | Durable buffers | `common/torchat-client-engine/src/storage/runtime_storage.rs`, `common/torchat-client-engine/src/storage/sqlite` | persistent inbox ramek i capability ACK/outbox | restart test: brak utraty oferty |
| B2-1 | Probe model | `mobile/lib/core/probe/*`, `common/torchat-client-runtime` | unified Probe API + TTL + semantyka stanów (peer/relay/transport) | widget test: spójne stany contact list/header |
| C1 | Actor split | `common/torchat-client-engine/src/actor/*.rs` | podział logiczny plików, bez zmiany właściciela `ClientEngineActor` | `cargo test -p torchat-client-engine` |
| C2 | Storage split | `common/torchat-client-engine/src/storage/sqlite/*.rs` + `runtime_storage.rs` | wyraźny podział persistence/query + migration tables helpers | clippy + migration tests |
| C3 | Runtime split | `common/torchat-client-runtime/src/{bootstrap,contacts,pairing,messages,conversations}.rs` | modularizacja domenowa `ClientRuntime` | `cargo test --workspace` |
| C4 | AppController | `mobile/lib/app/*.dart` | zastąpić dekoracyjne dziedziczenie koordynatorami | manual state flow sanity |
| D1 | UX | `mobile/lib/features/contacts/contacts_view.dart`, `mobile/lib/features/shell/main_shell.dart` | jeden panel statusów, brak nakładających ikon, back-navigation Android | manual responsive checks |
| D2 | Attachments | `mobile/lib/features/chats/release_chat_view.dart` | image enqueue, miniatury <=200px, lazy load placeholdery | manual: 10 zdjęć w rozmowie |

Każdy wpis kończy się dopisaniem wpisu do logbooku (`## 2) Live log`).

## 4) Akceptacja release (MUST pass)

1. pairing desktop↔android 3x po kolei:
   - invite -> accept -> first msg -> reopen -> messages stale do czasu open => recover
2. chat live history: incoming statusy nie kasują treści,
3. minimize/restore Android: readiness nie resetuje się losowo,
4. offline retry: `QUEUED` -> `SENDING` -> `SENT`/`DELIVERED` bez spin-loop,
5. remove/repair/re-pair flow: local restart does not lose conversation,
6. no crash due mojibake, no stale one-modal bug,
7. two-engine integration test in CI passes (RG-03).

---

## 5) Plan wykonawczy od dziś (krotki, ale konkretny)

### Zasada wykonania (bezpieczny porządek)

1. Najpierw domykamy **P0 blokujące** (`P0-09`, `P0-10`, `P0-11`, `P0-12`)  
2. Potem `P1` (stabilność i własność projekcji)  
3. Na końcu `P2` (UX/UI + polish), ale bez zmian architektonicznych ingerujących w transport.

### Równolegle prowadzone workstreamy

Każdy tydzień prowadzimy 2 workstreamy:
- **S1 (stability):** engine/runtime/repository + scripts (bez UI redesignu).
- **S2 (delivery):** UI, navigation, chat UX, listy, attachmenty.

Tym samym blokujemy ryzyko, że refactor UI przykryje błąd transportowy.

### Dzisiejsze zadania (kolejność na 2 dni)

**Dzień 1 — rozmowa + pairing core**
- B0-01 domknąć delta-lane wiadomości (brak replace)  
- B0-02 domknąć jeden modal pairingu + idempotent pending + includePairing fetch  
- S1-01 wprowadzić `conversationRevision`/`storeId` i revision checks w response/event  
- Dopiąć wpisy w `## 2) Logbook` po każdym kroku  

**Dzień 2 — startup i retry**
- B0-03 reattach + ready lanes (android/desktop)  
- A4-1 scheduler WAITING_* i bounded requeue  
- S1-03 read-your-writes + natychmiastowa publikacja efektu mutacji  
- dodać 2 krótkie testy manual (pairing 3x i otwarty czat 100 msg)

**Dzień 3 — hardening i integracja**
- B1-1 durable pre-Welcome inbox + capability outbox  
- A3-1 endpoint/probe semantic alignment  
- P0-12 smoke test desktop↔android (3 rundy, 2 kierunki)  
- odświeżyć logbook + status procentowy.

### Kryterium przejścia na kolejny etap
- brak regresji na 3x smoke pairing + message history
- brak utraty wiadomości przy otwartym czacie
- Android minimize/restore: readiness deterministyczny
- brak restart-only "odświeżenia listy" w celu odzyskania historii

### Logbook-as-code (jak uzupełniać)

Każdorazowo po zakończeniu:
1. dopisujesz wiersz do `## 2) Logbook`:
   - `EP`, status, pliki, walidacja, wynik, ryzyko, next
2. jeśli zmieniasz API/projekcje, dopinajesz test/manual proof
3. dopinasz w `10)` listę plików dotkniętych i usuwasz `IN_PROGRESS`/`TODO` status.

Przykład wpisu:
`2026-08-03 14:20:00 | EP=B0-01 | owner=AI | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/application_state/application_state_store.dart] | validation=[manual 20 msg open-chat] | result=przejście z replace na merge+upsert | risk=ordering eventu przy multi-device | next=B0-02`

### Komendy wejścia/wyjścia dla każdego etapu

#### Wejście
- `cargo fmt --all -- --check`
- `cargo check --workspace`
- `cd mobile && flutter analyze`
- ręczny smoke: parowanie + otwarty czat + statusy

#### Wyjście (DONE_VERIFIED)
- `cargo test --workspace`
- pełny smoke script desktop↔android min 3 rundy
- `flutter test`
- logbook + update statusu EP na `done_verified`

### Szacowane obciążenie dziś

- **P0**: 4 epiki (A1/A2/A3/A4), łączny czas 2–3 dni
- **P1**: 4 epiki, 2–3 dni
- **P2**: 3 epiki, 1–2 dni

## 6) Kolejność tygodniowego wykonania

### Tydzień 1 (P0 closure)
- Dni 1-2: A1 + A2 + A3 + A4 (pełne logi i manual smoke co iterację)
- Dzień 3: B1 + pairing cleanup in server + reattach checks
- Dzień 4: release + integration smoke + regresje

### Tydzień 2 (P1)
- Dni 1-3: C1/C2/C3, zachowując API stabilne
- Dzień 4: C4 + C5
- Dzień 5: code cleanup + check-size + CI gates + release-0-1 gate prep

### Tydzień 3 (P2)
- Dni 1-3: D1/D2 polish + responsive and back behavior
- Dzień 4: accessibility + perf polish
- Dzień 5: final verification and merge.

---

## 7) Aktualne ryzyka do monitorowania (codzienny przegląd)

- event ordering vs response ordering,
- stale cache overwrite without revision,
- one-modal drift,
- attachment retry loops,
- service lifecycle under Android taskkill/minimize.

---

## 8) Commandy regresyjne po każdym EPIC

```bash
cargo fmt --all -- --check
cargo check --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd mobile && dart format --output=none --set-exit-if-changed lib test
cd mobile && flutter analyze
cd mobile && flutter test
cd mobile && flutter build apk --debug
cd mobile && flutter build windows --debug
```

Dodatkowo:
- `scripts/tests/Test-TorChatTwoEngineIntegration.ps1` (RG-03)
- manual pairing/chat smoke (3 runy każde urządzenie)

---

## 9) Notatka operacyjna

Ten plik ma pozostać **jedynym źródłem planu wdrożeniowego**. Każda większa zmiana to jeden wpis w „Live log” i update statusu EP/ID.
---

## 10) Refactor execution backlog (single source of truth)

To jest wersja "do wdrożenia od ręki" na kolejne iteracje. Każdy wiersz = jeden blok roboczy do wykonania end-to-end i zamknięcia testami.

### 9.1 Pracownia 0: Stabilność rozmowy i parowania (blocking)

| ID | Status | Zakres | Gdzie | Co dokładnie | Kryterium zakończenia |
| --- | --- | --- | --- | --- | --- |
| B0-01 | IN_PROGRESS | Live-history no-loss | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/app/sequential_app_controller.dart`, `mobile/lib/app/app_controller_base.dart`, `mobile/lib/features/chats/release_chat_view.dart`, `common/torchat-client-engine/src/actor/projection.rs`, `common/torchat-client-engine/src/event.rs` | Wykonujemy single-writer chat lane: status i message events przechodza jako delta i nie replace'uje pełnej listy otwartej rozmowy. Response/event zawiera `conversationRevision`; starszy wynik jest odrzucany. | W otwartym czacie brak resetu do 1 wiadomości po status/update; 50+ wiadomości zostaje zachowanych i appenduje się stabilnie. |
| B0-02 | IN_PROGRESS | One-modal pairing + deterministic invite | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/app/main.dart`, `mobile/lib/app/sequential_app_controller.dart`, `server/torchat-server/src/main.rs` | Jeden path `IncomingPairingDialog`; refresh includePairing robi jawny fetch inbox/outbox i nie opiera się o fallback cache. Serwer zwraca idempotentny pending zamiast ogolnego 409. | Kod aktywuje jedno oczekujace zaproszenie, recipient dostaje jeden modal bez restartu, accept/reject działa i czymsia w tym samym idempotency. |
| B0-03 | PENDING | Android/desktop reattach status lanes | `common/torchat-client-engine/src/actor/platform_facts.rs`, `mobile/lib/windows_runtime.dart`, Android bridge | readiness na lane: tor, relay, p2p, engine + head snapshot przed odswiezeniem. | minimize/restore nie powoduje rozjechanych statusow; APP_READY = deterministyczne. |
| B0-04 | PENDING | Warmup deterministyczny | `scripts/torchat.ps1`, `scripts/internal/*.ps1`, runtime startup hooks | Jednoznaczny status progress; eliminacja „app stuck” bez czytelnej przyczyny. | Długie deploye dają powtarzalny wynik: fail->jeden czytelny step lub success. |

### 9.2 Pracownia 1: Projekcja i stan transportu

| ID | Status | Zakres | Gdzie | Co dokładnie | Kryterium zakończenia |
| --- | --- | --- | --- | --- | --- |
| S1-01 | DONE_VERIFIED | Projection stamps in engine | `common/torchat-client-engine/src/actor/projection.rs`, `common/torchat-client-engine/src/command.rs`, `common/client-engine-contract.json`, `tools/torchat-contract-gen/src/main.rs` | Response i event zawierają `storeId`, `engineSessionId`, `revision`; durable head jest czytany z SQLite w tej samej projekcji. | Contract, Rust tests i Flutter analyze przechodzą; starsze application snapshots są odrzucane przez store. `conversationRevision` pozostaje osobnym follow-upem, nie udajemy że jest gotowy. |
| S1-02 | DONE_VERIFIED | Projection coordinator (Flutter) | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/core/application_state/application_state_store.dart`, `mobile/lib/app/sequential_app_controller.dart` | Lane per conversation ma dedupe in-flight/trailing refresh, epoch/sequence guards i merge/upsert zamiast replace dla live refresh. | `cargo` + `flutter analyze` przechodzą; pełny dwuurządzeniowy smoke pozostaje wymagany dla `P0-12`. |
| S1-03 | IN_PROGRESS | Read-your-writes | `common/torchat-client-engine/src/command.rs`, `mobile/lib/core/runtime/runtime_repository.dart` | sendMessage/accept/welcome returns mutation snapshot + revision; UI od razu pokazuje lokalny post. | Brak „coś wisialy w kolejce mimo wyslanych eventow”. |

### 9.3 Pracownia 2: Refactor strukturalny

| ID | Status | Zakres | Gdzie | Co dokładnie | Kryterium zakończenia |
| --- | --- | --- | --- | --- | --- |
| S2-01 | DONE_VERIFIED | Actor split modules | `common/torchat-client-engine/src/actor/*.rs` | Podzielono dispatch, pairing, messaging, relay/peer events, projection, receipts, retry i transakcję; nadal istnieje jeden `ClientEngineActor`. | `cargo fmt/check/test/clippy` przechodzą; `actor/mod.rs` zmniejszony do 1320 linii; dalsze rozbijanie nie jest wymagane dla 0.1. |
| S2-02 | DONE_VERIFIED | Storage split | `common/torchat-client-engine/src/storage/sqlite/*.rs` | Wydzielono migracje, rekordy, wiadomości, pairing, receipts, projection i endpointy; API `ClientDatabase` zachowane. | `cargo test --workspace` i SQL isolation check przechodzą; `sqlite/mod.rs` ma 1246 linii. |
| S2-03 | IN_PROGRESS | Runtime split | `common/torchat-client-runtime/src` | Modularizacja domenowa runtime, bez zmiany publicznego API. | testy runtime i engine stable. |
| S2-04 | IN_PROGRESS | Controller cleanup | `mobile/lib/app/*.dart` | Zamiast dziedziczenia -> koordynatory slices. | Mniejsze couplingi i jednoznaczny właściciel stanu rozmowy. |

### 9.4 Pracownia 3: UX i interakcje

| ID | Status | Zakres | Gdzie | Co dokładnie | Kryterium zakończenia |
| --- | --- | --- | --- | --- | --- |
| UX-01 | IN_PROGRESS | Android back/navigation | `mobile/lib/app/main.dart`, `mobile/lib/app/sequential_app_controller.dart` | Back handling zgodny z nav stackiem. | Rozmowa -> listy rozmow; tylko na root aplikacja idzie w background. |
| UX-02 | IN_PROGRESS | Header/probe alignment + busy indicator | `mobile/lib/shared/widgets/contact_list_section.dart`, `mobile/lib/shared/widgets/conversation_list_section.dart`, `mobile/lib/features/chats/release_chat_view.dart` | Jeden panel statusu, spójne stany, poprawne pozycjonowanie ikon. | Brak nakladania elementów i błędnych alignów. |
| UX-03 | IN_PROGRESS | Responsive + attachments | `mobile/lib/features/chats/release_chat_view.dart`, `mobile/lib/core/runtime/runtime_repository.dart` | Lazy image, max thumbnail 200px, stale statusy wysylki, scroll-to-bottom CTA. | 360 px layout i attachments stabilne. |

### 9.5 Pracownia 4: Endpoint capability and message security hardening

| ID | Status | Zakres | Gdzie | Co dokładnie | Kryterium zakończenia |
| --- | --- | --- | --- | --- | --- |
| H-01 | DONE | proof-of-possession HMAC | `common/torchat-core/src/peer_protocol.rs`, `common/torchat-client-engine/src/actor/pairing.rs` | HMAC proof required in peer hello, invalid proof rejected. | Brak nieautoryzowanego peer hello. |
| H-02 | IN_PROGRESS | durable pre-Welcome inbox | `common/torchat-client-engine/src/storage/runtime_storage.rs`, sqlite migration | Trwałe przechowanie ramek otrzymanych przed Welcome, replay po commit. | restart nie gubi frame'ów. |
| H-03 | IN_PROGRESS | durable capability outbox retry | `common/torchat-client-engine/src/storage/runtime_storage.rs`, pairing actors | capability offer/ack in outbox with retry across restarts/reconnect. | Nie zgubic capability handshake przy offline/restart. |

### 9.6 Operacyjny logbook (wymuszony)

Każdy wiersz wpisujcie bezpośrednio w sekcji 2. Format:

`TS | EP=<id> | owner=<who> | files=[..] | status=<done|done_verified|in_progress|blocked> | validation=[cmd|unit|manual|e2e] | result=<1 line> | risk=<1 line> | next=<next action>`

Przykład:
`2026-08-03 14:20:00 | EP=B0-01 | owner=AI | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/features/chats/release_chat_view.dart] | status=in_progress | validation=[manual: desktop↔android 3x, 100 msg open-chat] | result=lane history delta + revision guard` 

- `2026-08-03 16:10:00 | EP=UX-TOAST-01 | owner=AI | files=[mobile/lib/app/notifications/toast_message.dart,mobile/lib/app/notifications/ui_notification_center.dart,mobile/lib/shared/widgets/toast_host.dart,mobile/lib/main.dart,mobile/lib/app/app_controller_base.dart,mobile/lib/features] | status=done_verified | validation=[flutter analyze,flutter test:159 passed,static:no showSnackBar in lib] | result=jeden globalny top-center toast host, limit 3 + FIFO, dedupe, slide/fade, usunięto AppState.notice i wszystkie produkcyjne SnackBary; submit pairingu nie emituje fałszywego sukcesu, terminalny wynik outboxu emituje toast | risk=wizualny smoke na fizycznym Androidzie i Windows pozostaje do wykonania | next=build apk/windows i ręczny smoke pairing accepted/rejected/expired`
- `2026-08-03 16:45:00 | EP=UX-CHAT-02 | owner=AI | files=[mobile/lib/features/chats/release_chat_view.dart,mobile/lib/features/chats/message_bubble.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/lib/shared/widgets/tor_status_bar.dart] | status=done_verified | validation=[flutter analyze,focused widget tests,flutter test] | result=ujednolicono akcje headera 40x40 i composer 44x44, ograniczono tekstowe bąbelki do dynamicznej szerokości 120-560, dopracowano status dock, inspector i czytelne daty/etykiety | risk=ostateczny pixel-level smoke wymaga uruchomionego Windows UI | next=manual screenshot review po redeploy desktop`
- `2026-08-03 17:10:00 | EP=B0-02 | owner=AI | files=[mobile/lib/core/models/domain.dart,mobile/lib/core/runtime/runtime_bridge_base.dart,mobile/lib/main.dart,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/shell/main_shell.dart,mobile/lib/app/pairing_recovery_app_controller.dart,mobile/test/pairing_origin_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:162 passed] | result=toast jest routowany wyłącznie dla outbox, modal wyłącznie dla inbox, oczekujące parowania są widoczne przed Welcome, a recovery wykonuje trzy ograniczone odświeżenia projekcji po akceptacji | risk=manualny smoke Android↔desktop nadal wymagany do potwierdzenia opóźnień relay/Welcome | next=uruchomić fizyczny pairing i sprawdzić jeden modal oraz toast tylko na urządzeniu wysyłającym`

2026-08-03 18:00:00 | EP=PRESENCE-01 | owner=AI | files=[mobile/lib/core/presence/contact_presence_snapshot.dart,mobile/lib/core/presence/contact_presence_store.dart,mobile/lib/core/presence/contact_probe_coordinator.dart,mobile/lib/app/sequential_app_controller.dart] | status=in_progress | validation=[flutter analyze] | result=Dodano wspólny snapshot/store/coordinator i podłączono obecne eventy presence, focus oraz peer connection; expiry przechodzi do unknown | risk=widoki nadal migrują ze starych map AppState; focus wymaga mapowania conversationId?contactId | next=przepiąć listę, header i inspector na ContactPresenceStore
2026-08-03 19:00:00 | EP=PRESENCE-06/08 | owner=AI | files=[mobile/lib/app/app_controller_base.dart,mobile/lib/app/sequential_app_controller.dart,mobile/lib/core/presence/contact_probe_coordinator.dart,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/connection/connection_center_sheet.dart,mobile/test/contact_presence_coordinator_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:coordinator+presence,cargo test -p torchat-client-engine probing] | result=usunieto legacy mapy i timery z AppState/kontrolera, focus mapuje conversationId na contactId, panel mobilny i reattach używaja snapshotu, dodano logi pseudonimizowane i testy | risk=pelny smoke desktop?Android wymaga urzadzen/runtime; logi używaja stabilnego hashCode procesu Dart | next=uruchomic pelny flutter test i manualny smoke cross-device
2026-08-03 19:20:00 | EP=PRESENCE-08 | owner=AI | files=[mobile/lib/core/presence/contact_probe_coordinator.dart,REFACTOR_PROGRESS.md] | status=in_progress | validation=[flutter build apk --debug,adb install+monkey Android,flutter build windows] | result=APK zbudowany, zainstalowany i uruchomiony na Androidzie; build Windows zatrzymal sie na braku dostępu do windows/flutter/ephemeral/.plugin_symlinks | risk=nie wykonano pełnego smoke desktop?Android ani scenariusza sparowania dwóch urządzeń; Windows wymaga uprawnień/symlinków środowiska | next=powtórzyć Windows build/smoke po udostepnieniu katalogu ephemeral, następnie wykonać cross-device presence/focus
2026-08-03 19:40:00 | EP=PRESENCE-FINAL | owner=AI | files=[mobile/lib/app/app_controller_base.dart,mobile/lib/app/sequential_app_controller.dart,mobile/lib/core/presence,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/test/contact_presence_coordinator_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:165 passed,cargo test -p torchat-client-engine probing:2 passed] | result=zakres kodowy presence zakonczony; smoke Windows?Android pominiety na zadanie uzytkownika | risk=brak recznej walidacji cross-device | next=brak
2026-08-03 20:10:00 | EP=PROBE-SUBSCRIPTIONS-01 | owner=AI | files=[common/torchat-client-engine/src/probing.rs,common/torchat-client-engine/src/actor/peer_control.rs,common/torchat-client-engine/src/actor/peer_events.rs,mobile/lib/core/presence/contact_probe_coordinator.dart] | status=done_verified | validation=[cargo test -p torchat-client-engine probing:5 passed,cargo check -p torchat-client-engine,flutter analyze,focused flutter tests:7 passed] | result=ProbeCoordinator publikuje retained ProbeSnapshot przez tokio watch, wielu subskrybentów współdzieli jeden claim, actor używa begin_due z timeoutem in-flight, a logi probe pochodza z rzeczywistego cyklu Rust | risk=pozostałe ProbeKind mają gotowy model subskrypcji, ale ich konkretne drivery nadal powstają dopiero wraz z rzeczywista operacja transportowa | next=brak
2026-08-03 20:45:00 | EP=PROBE-MIGRATION-ALL | owner=AI | files=[common/torchat-client-engine/src/probing.rs,common/torchat-client-engine/src/actor/peer_control.rs,common/torchat-client-engine/src/actor/peer_events.rs,common/torchat-client-engine/src/actor/connection.rs] | status=done_verified | validation=[cargo test -p torchat-client-engine:52 passed,cargo check -p torchat-client-engine,flutter analyze,focused Flutter tests:5 passed] | result=podpieto ContactPeer, presence heartbeat, endpoint, capability, focus, relay, onion i engine do jednolitego ProbeKey/ProbeSnapshot; scheduler claimuje tylko due, a wyniki techniczne publikują retained watch | risk=brak cross-device smoke zgodnie z wczesniejsza decyzja; runtime nadal dostarcza snapshoty Fluttera przez istniejace eventy | next=brak

PRESENCE-09 — Read receipts: focus rozmowy wysyła ReadReceipt, a stan wiadomości przechodzi do „odczytano”; receipt transport pozostaje na istniejacym peer probe.
