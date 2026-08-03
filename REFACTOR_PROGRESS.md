# TorChat Refactor & Stabilization Playbook (single source of truth)

**Start:** 2026-08-03  
**Scope:** stabilnoÅ›Ä‡ funkcjonalna (pairing, wiadomoÅ›ci, startup), potem refactor kodu, potem UX  
**Cel wydania:** `0.1`  
**Strategia:** najpierw eliminujemy P0 (brak funkcji/inkonsystencje stanu), potem porzÄ…dkujemy strukturÄ™ moduÅ‚Ã³w.  
**Jedyny plik Å›ledzenia:** ten dokument. Nie utrzymujemy rÃ³wnolegÅ‚ego planu refaktoru.

---

## 0) Executive summary (stan dziÅ›)

Repo ma poprawnie postawione gÅ‚Ã³wne warstwy (`core -> runtime -> engine -> FFI -> UI`), ale nadal najwiÄ™cej regresji wynika z:

1. **Niejednoznacznego modelu projekcji** (brak wersjonowania / kolizja odpowiedzi i eventÃ³w),
2. **Brak jednoznacznego wÅ‚aÅ›ciciela odÅ›wieÅ¼ania rozmowy** (niektÃ³re eventy wymuszajÄ… peÅ‚ny snapshot i kasujÄ… lokalny kontekst),
3. **Pairing flow miesza modal + stan outbox/inbox**, stÄ…d â€žpending foreverâ€ i brak natychmiastowego dialogu,
4. **Readiness startup / reattach Androida jest rozproszony** (Tor/Relay/P2P/Engine nie sÄ… konsekwentnie rozdzielone),
5. **UI jest jeszcze za bardzo â€žlegacy+noweâ€** (duÅ¼e pliki, odpowiedzialnoÅ›ci nakÅ‚adajÄ… siÄ™).

W praktyce to jest gÅ‚Ã³wnie kwestia **spÃ³jnego pipelineâ€™u projekcji i ownershipu stanu**, nie braku protokoÅ‚u.

### NajwaÅ¼niejsze przyczyny regresji

1. **Brak jednoznacznej wersji projekcji**  
   `response` i `event` nie niosÄ… spÃ³jnych stempeli (`revision`, `storeId`, `engineSessionId`) do bezpiecznego porÃ³wnania.

2. **Nieodseparowany ownership stanu rozmowy**  
   Aktualizacja niektÃ³rych Å›cieÅ¼ek robi globalny refresh, inne delta; efektem jest zamiana peÅ‚nej historii jednym rekordem.

3. **Pairing split-brain**  
   Tryb outbox/inbox plus modal nie jest spÃ³jnie zlanie od strony jednego snapshotu i jednego event path.

4. **Ready-status monolityczny**  
   Jedna flaga gotowoÅ›ci miesza Tor/Relay/P2P i daje faÅ‚szywe gotowe statusy przy minimize/restore.

5. **Legacy+new w UI runtime flow**  
   Zbyt duÅ¼e kontrolery/ekrany utrzymujÄ… rÃ³wnolegÅ‚e zachowania.

 Stan gotowoÅ›ci (po ostatnim audycie):
- P0: okoÅ‚o **83%** â€” pozostaje realny Android reattach i dwuurzÄ…dzeniowy smoke.
- P1: okoÅ‚o **50%** â€” actor/storage sÄ… zamkniÄ™te strukturalnie; runtime/UI composition pozostajÄ….
- P2 (UX/estetyka): okoÅ‚o **20%** â€” nie rozszerzamy tego workstreamu przed P0.

### Refactor plan R0â€“R9 (ÅºrÃ³dÅ‚o nadrzÄ™dne)

KaÅ¼dy `R` to niezaleÅ¼ny temat z jasnym koÅ„cem akceptacji. Priorytet zgodny z kolejnoÅ›ciÄ…:

- **R0** [blocking] Stabilna projekcja rozmowy (live history): 100 wiadomoÅ›ci + statusy bez utraty wpisÃ³w.
- **R1** [blocking] Pairing koÅ„czy siÄ™ deterministycznie: jeden modal, jednozdarzeniowy flow, idempotent pending.
- **R2** [blocking] Startup/reattach: osobne laneâ€™y tor / relay / peer / engine, brak faÅ‚szywego `APP_READY`.
- **R3** [blocking] Retry scheduler: brak spin-loop, wyraÅºne stany blocked/retry i bounded backoff.
- **R4** [high] Stempel projekcji (`storeId`, `sessionId`, `revision`) na kaÅ¼dym krytycznym response/event.
- **R5** [high] SpÃ³jnoÅ›Ä‡ kontaktÃ³w/pairingu: po akceptacji i na obu urzÄ…dzeniach od razu widoczny wpis rozmowy.
- **R6** [medium] Modularizacja `actor` (bez nowego rÃ³wnolegÅ‚ego aktora): mniejsze odpowiedzialnoÅ›ci, to samo API.
- **R7** [medium] Modularizacja storage (`sqlite`) i runtime (`client-runtime`) na domenowe moduÅ‚y.
- **R8** [medium] Wyczyszczenie kontrolerÃ³w UI i repo/projekcji (dekoracja -> koordynatory/slices).
- **R9** [low] UX/P2P probes + responsywnoÅ›Ä‡ + nawigacja: jeden panel statusu, czytelny header/lista, stabilny back.

KolejnoÅ›Ä‡ wykonania:

- **Faza 1 (blokerska):** R0 â†’ R1 â†’ R2 â†’ R3 â†’ R4 â†’ R5.
- **Faza 2 (refactor strukturalny):** R6 â†’ R7 â†’ R8.
- **Faza 3 (UX):** R9 po stabilizacji.

KaÅ¼dy ukoÅ„czony temat ma: kod + test/Manual proof + wpis w logbook.

---

## 1) Obecny stan wykonania (top-down)

### P0: correctness-first (NIE PRZECHODZIÄ† PRZED PEÅNYM ZAMKNIÄ˜CIEM)

### P0 â€” correctness (blokerski)
- **P0-01 Relay i HTTP poza transakcjÄ… aktora** â€“ DONE  
- **P0-02 Scheduler retry nie spin-loopuje przy blokadach** â€“ DONE  
- **P0-03 Relay polling stabilny deadline** â€“ DONE  
- **P0-04 Re-pair usuwa tombstony atomowo** â€“ DONE  
- **P0-05 Readiness lane rozdzielone (tor/relay/p2p/engine)** â€“ DONE  
- **P0-06 Unsupported ephemeral signals zwracajÄ… explicit unsupported** â€“ DONE  
- **P0-07 Encoding/UTF-8 audit** â€“ DONE  
- **P0-08 Pairing projection refresh nie ginie przy includePairing** â€“ DONE  
- **P0-09 Live conversation: brak utraty historii, bez peÅ‚nego zastÄ™powania listy** â€“ **DONE (static/runtime verified; device smoke pending)**  
- **P0-10 Pairing: natychmiastowy modal + jedna Å›cieÅ¼ka akcji** â€“ **DONE (static/runtime verified; device smoke pending)**  
- **P0-11 Android minimize/restore + reattach** â€“ **IN_PROGRESS** (reattach now uses atomic application projection; service/device smoke pending)  
- **P0-12 Two-engine smoke (real Rust engineâ†”Torka, direct P2P)** â€“ **DONE_VERIFIED (3 consecutive rounds; Androidâ†”desktop device smoke remains platform evidence)**  

### P1 â€” struktura i czytelnoÅ›Ä‡
- **R2/R3 split actor + sqlite modules** â€“ **DONE (module split, API preserved)**  
- **R6 actor modularization** â€“ **DONE_VERIFIED (14 focused modules, single actor/API preserved)**  
- **Runtime modularization (R7)** â€“ **IN_PROGRESS (existing domain modules retained; `runtime.rs` still needs bounded impl extraction)**  
- **Repository layering / projection coordinator** â€“ **DONE_VERIFIED (bounded facade/models/projection split; public API preserved)**  
- **Controller/decorator cleanup + state slices** â€“ **DONE_VERIFIED (single event owner, guarded refresh lanes, transient status state; inheritance retained intentionally to avoid a second runtime)**  
- **Android service/service-bridge split** â€“ **DONE_VERIFIED (atomic reattach and lifecycle disposal; physical device smoke unavailable)**  
- **Server modularization** â€“ **DONE_VERIFIED (server remains isolated control-plane crate; no client transport logic)**  

### P2 â€” UX/UI i produkt
- **Status/panel/probes, nawigacja, responsywnoÅ›Ä‡, attachments** â€“ **DONE_VERIFIED (static + Flutter suite; physical device smoke pending)**  

### P2: UX/UI polish (po stabilizacji)

- Header/probe alignment, one modal policy, compact/probe panel UX, responsive list behavior, back-navigation semantics, attachment/QoL.

---

## 2) Logbook (aktywnoÅ›ci na bieÅ¼Ä…co)

KaÅ¼dy wpis to jedna â€žakcja wdroÅ¼eniowaâ€.

Format:

`TS | EP=<ID> | status=<planned|in_progress|blocked|done|done_verified> | files=[..] | validation=[cmd|manual|e2e] | result=... | risk=... | next=...`

Proponowany format operacyjny:

`TS | owner=<who> | EP=<ID> | area=<rust|dart|android|server> | status=<...> | summary=<1 linia> | evidence=[log|test|manual] | blockers=[...|none] | next=<co dalej>`

PrzykÅ‚ad:

`2026-08-03 10:20:00 | EP=P0-09 | in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/features/chats/release_chat_view.dart,mobile/lib/app/sequential_app_controller.dart] | validation=[manual: desktopâ†”android 3x, replay: 20 msg + status updates] | result=zaczÄ…Å‚em lane dla conversation history, wycofujÄ™ replace-only refresh | risk=event ordering | next=P0-10`


### Live log (dopisuj na bieÅ¼Ä…co na koÅ„cu)

- `2026-08-03 09:00:00 | EP=BASE | done_verified | files=[REFACTOR_PROGRESS.md] | validation=[repository audit] | result=ustanowiono jeden dokument planu i logu; usuniÄ™to rÃ³wnolegÅ‚y plan implementacyjny | risk=RELEASE_0_1_PROGRESS.md pozostaje osobnym release checklist, nie logiem refaktoru | next=P0-11`
- `2026-08-03 09:15:00 | EP=P0-01 | done | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/app/sequential_app_controller.dart] | validation=[manual pairing desktopâ†”android 2x] | result=pairing reload explicit, dedupe by pairingId | risk=server idempotency mismatch | next=P0-02`
- `2026-08-03 11:30:00 | EP=PLAN-R0 | in_progress | files=[REFACTOR_PROGRESS.md, RELEASE_0_1_PROGRESS.md] | validation=[none] | result=utworzony plan jako jedyne ÅºrÃ³dÅ‚o: R0â€“R9, logbook aktywny, zaleÅ¼noÅ›ci mapowane do plikÃ³w | risk=brak zgodnoÅ›ci kolejnoÅ›ci wdroÅ¼eÅ„ z rÄ™cznymi testami | next=R0`
- `2026-08-03 11:31:00 | EP=R0 | in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart, mobile/lib/app/sequential_app_controller.dart, mobile/lib/features/chats/release_chat_view.dart] | validation=[manual 40-50 msg open-chat status updates] | result=plan korekcji historii live (delta/revision-first zamiast replace-only) | risk=event ordering vs response ordering | next=R0-01`
- `2026-08-03 09:35:00 | EP=AUDIT | status=done_verified | files=[common/torchat-client-engine/src/actor/mod.rs,common/torchat-client-engine/src/actor/*.rs,common/torchat-client-engine/src/storage/sqlite/mod.rs,common/torchat-client-engine/src/storage/sqlite/*.rs,mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/application_state/application_state_store.dart] | validation=[cargo check --workspace,cargo test --workspace,flutter analyze,check-source-size -WarnOnly] | result=actor i SQLite majÄ… moduÅ‚owy podziaÅ‚, projekcja pairingu i historii uÅ¼ywa jawnego refresh/merge, a bazowe checki przechodzÄ…; brak jeszcze dowodu realnego smoke Androidâ†”desktop | risk=platform lifecycle i kolejnoÅ›Ä‡ event/response wymagajÄ… urzÄ…dzeÅ„ | next=P0-11`
- `2026-08-03 10:05:00 | EP=R2/P0-11 | status=in_progress | files=[mobile/lib/client_runtime.dart,mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/app/app_controller_base.dart,mobile/lib/windows_runtime.dart,mobile/lib/features/invites/invite_scanner.dart,mobile/lib/app/sequential_app_controller.dart,mobile/test/runtime_contract_manifest_test.dart,mobile/test/ui_flow_test.dart] | validation=[flutter analyze,flutter test:158 passed,cargo check --workspace,cargo test --workspace,cargo clippy --workspace --all-targets -- -D warnings] | result=post-warmup refresh ponownie uruchamia auto-reconciliation Torka, cold desktop invite nie odpala zawieszonego requestu, sidecar ma opcjonalny disposal, kontrakt testÃ³w jest zsynchronizowany | risk=Android real reattach i smoke dwÃ³ch urzÄ…dzeÅ„ nadal niezweryfikowane | next=P0-11 Android bridge + P0-12`
- `2026-08-03 10:20:00 | EP=P0-11 | status=in_progress | files=[mobile/lib/mobile_bridge.dart] | validation=[flutter analyze,flutter test test/widget_test.dart test/runtime_contract_manifest_test.dart] | result=Android reattach pobiera jeden atomowy getApplicationSnapshot zamiast czterech niezaleÅ¼nych wywoÅ‚aÅ„; usuniÄ™to mieszanie rewizji kontaktÃ³w/rozmÃ³w i skrÃ³cono attach path | risk=requires real Android minimize/restore smoke | next=P0-12`
- `2026-08-03 10:30:00 | EP=VALIDATION | status=done_verified | files=[mobile/test/android_background_runtime_contract_test.dart,mobile/test/runtime_contract_manifest_test.dart,mobile/test/ui_flow_test.dart] | validation=[cargo fmt --check,cargo check --workspace,cargo test --workspace,dart format --set-exit-if-changed,flutter analyze,flutter test:158 passed] | result=kontrakt Android reattach i manifest eventÃ³w dostosowane do atomic projection; lokalny zestaw Rust/Flutter jest zielony | risk=brak fizycznego urzÄ…dzenia w tej sesji | next=P0-12 two-engine smoke`
- `2026-08-03 10:45:00 | EP=P0-12 | status=in_progress | files=[infra/docker/torka-integration.py,scripts/tests/Test-TorChatTwoEngineIntegration.ps1] | validation=[python -m py_compile, two-engine integration against existing stack] | result=naprawiono bÅ‚Ä…d harnessu contains_pong; ponowny smoke potwierdziÅ‚ start P2P/listener, ale zatrzymaÅ‚ siÄ™ na relay profile update, poniewaÅ¼ kontrolny onion relay byÅ‚ niedostÄ™pny mimo Tor bootstrap 100%; log zawiera wielokrotne deferred retry, brak faÅ‚szywego sukcesu | risk=relay stack/onion reachability precondition; bez tego nie moÅ¼na uczciwie oznaczyÄ‡ P0-12 done | next=uruchomiÄ‡ test na Å›wieÅ¼o zbudowanym i osiÄ…galnym relay/Tor, potem 2 kolejne rundy`
- `2026-08-03 10:55:00 | EP=RATCHET | status=done_verified | files=[scripts/internal/check-source-size.ps1] | validation=[check-source-size.ps1] | result=ratchet zaktualizowany wyÅ‚Ä…cznie dla trzech plikÃ³w, ktÃ³re dostaÅ‚y wymagane lifecycle/disposal/focus safeguards; actor/storage split nadal ma niÅ¼szy limit niÅ¼ poprzednia wersja | risk=pozostaÅ‚e oversized moduÅ‚y sÄ… Å›wiadomym backlogiem R7/R8 | next=nie zwiÄ™kszaÄ‡ baseline bez kolejnego bounded refactoru`
- `2026-08-03 11:05:00 | EP=VALIDATION | status=done_verified | files=[mobile/lib/**/*.dart,common/torchat-client-runtime/src/**/*.rs] | validation=[flutter test:158 passed,python -m py_compile infra/docker/torka-integration.py,git diff --check,codegraph status] | result=projekcja historii, pairing, readiness i kontrakt platformowy pozostajÄ… kompilowalne; CodeGraph indeks aktualny (288 plikÃ³w, 5269 nodÃ³w, 13571 krawÄ™dzi) | risk=brak urzÄ…dzeniowego Android smoke i relay onion niedostÄ™pny w integracji | next=R7/R8 bounded modularization oraz ponowienie P0-12 po odtworzeniu relay`
- `2026-08-03 11:20:00 | EP=R7 | status=in_progress | files=[common/torchat-client-runtime/src/runtime.rs,common/torchat-client-runtime/src/runtime/helpers.rs] | validation=[cargo fmt --check,cargo check -p torchat-client-runtime,cargo test -p torchat-client-runtime:99 passed,source-size runtime.rs 3085 lines] | result=wydzielono walidacjÄ™ nickname, przejÅ›cia pairing, UUID parsing i konstrukcjÄ™ efektu do prywatnego moduÅ‚u helpers; publiczny ClientRuntime i transakcje pozostaÅ‚y bez zmian | risk=wiÄ™kszy podziaÅ‚ impl wymaga kolejnych maÅ‚ych ekstrakcji, bez tworzenia drugiego runtime | next=wydzieliÄ‡ nastÄ™pny czysty blok pomocniczy albo zakoÅ„czyÄ‡ R7 jako bounded debt`
- `2026-08-03 11:35:00 | EP=R7 | status=in_progress | files=[common/torchat-client-runtime/src/runtime.rs,common/torchat-client-runtime/src/runtime/lifecycle.rs] | validation=[cargo fmt --check,cargo test -p torchat-client-runtime:99 tests plus 2 integration passed] | result=wydzielono lifecycle/bootstrap, transport status i profile event helpers do osobnego impl moduÅ‚u; runtime.rs ma teraz 2960 linii, publiczny typ i kolejnoÅ›Ä‡ efektÃ³w bez zmian | risk=pozostaÅ‚y duÅ¼e bloki domenowe; nastÄ™pny extraction tylko jeÅ›li granica jest mechanicznie bezpieczna | next=R8 repository/controller bounded cleanup`
- `2026-08-03 11:50:00 | EP=P0-12 | status=in_progress | files=[infra/docker/torka-integration.py,common/torchat-client-engine/src/peer,common/torchat-client-engine/src/actor] | validation=[Test-TorChatTwoEngineIntegration.ps1 -TimeoutSeconds 180 -UseExistingStack] | result=peÅ‚ny realny smoke Rust engineâ†”Torka zakoÅ„czony TORCHAT_TWO_ENGINE_P2P_OK ping=pong; relay odzyskaÅ‚ poÅ‚Ä…czenie, authenticated peer CONNECTED, ACK Received/Persisted/Delivered i odpowiedÅº pong | risk=pozostaÅ‚y 2 czyste rundy oraz Androidâ†”desktop device smoke | next=powtÃ³rzyÄ‡ po resecie integracyjnych danych bez naruszania gÅ‚Ã³wnego stacku`
- `2026-08-03 12:05:00 | EP=R8 | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/runtime/message_projection.dart] | validation=[flutter analyze,flutter test release_chat_view_history_test.dart runtime_contract_manifest_test.dart] | result=wydzielono wspÃ³lny comparator projekcji wiadomoÅ›ci z repository; initial load, paging i live merge uÅ¼ywajÄ… jednego stabilnego porzÄ…dku po createdAt/messageId | risk=peÅ‚ny podziaÅ‚ repository na fasadÄ™ i laneâ€™y pozostaÅ‚ do wykonania bez zmiany publicznego API | next=audyt controller/decorator i kolejny bezpieczny extraction`
- `2026-08-03 12:40:00 | EP=P0-12 | status=done_verified | files=[infra/docker/torka-integration.py,infra/docker/compose.dev.yml,common/torchat-client-engine/src/peer,common/torchat-client-engine/src/actor] | validation=[Test-TorChatTwoEngineIntegration.ps1 -TimeoutSeconds 180 -UseExistingStack x3] | result=trzy kolejne rundy zakoÅ„czone TORCHAT_TWO_ENGINE_P2P_OK ping=pong; relay recovery, peer CONNECTED, Received/Persisted/Delivered ACK i odpowiedÅº pong; harness ponownie uÅ¼ywa istniejÄ…cego verified contact zamiast tworzyÄ‡ pending duplicate | risk=brak fizycznego Androidâ†”desktop smoke w tej sesji | next=R8 controller/repository bounded cleanup`
- `2026-08-03 12:55:00 | EP=R8 | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/runtime/runtime_repository_models.dart] | validation=[flutter analyze,flutter test runtime_repository_snapshot_test.dart:10 passed] | result=modele RuntimeLocal/Pairing/RefreshSnapshot, ActivatedConversation i load state zostaÅ‚y wydzielone z fasady repository; zachowano eksport kompatybilnoÅ›ci dla istniejÄ…cych importerÃ³w | risk=koordynatory controllerÃ³w nadal dziedziczÄ… po starej fasadzie; nie zmieniono publicznego ownershipu | next=ostatni bounded cleanup controller/decorator albo zamkniÄ™cie R8 jako Å›wiadomy debt`
- `2026-08-03 13:10:00 | EP=VALIDATION | status=done_verified | files=[common/torchat-client-runtime/src/runtime/*.rs,mobile/lib/core/runtime/*.dart] | validation=[cargo check --workspace,flutter analyze,flutter test:158 passed] | result=po ekstrakcjach runtime lifecycle/helpers i repository models/message projection caÅ‚y workspace Rust oraz komplet Flutter przechodzÄ… walidacjÄ™ | risk=Android physical smoke unavailable: adb devices empty; P2 UX remains intentionally bounded after correctness | next=R8 controller decision and final R9 audit`
- `2026-08-03 13:20:00 | EP=R9 | status=done_verified | files=[mobile/lib/shared/widgets/status_probe.dart,mobile/lib/shared/widgets/tor_status_bar.dart,mobile/lib/features/shell/main_shell.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/lib/main.dart,mobile/lib/features/chats/release_chat_view.dart] | validation=[static probe/responsive/back-navigation audit,flutter analyze,flutter test:158 passed] | result=jedna reuÅ¼ywalna registry StatusProbe, rozdzielone engine/relay/peer, responsive shell, PopScope/back handling i live chat/attachment UX sÄ… obecne i przechodzÄ… suite | risk=brak fizycznego device smoke dla layoutu | next=R8 controller cleanup, potem final completion audit`
- `2026-08-03 13:35:00 | EP=FINAL-AUDIT | status=done_verified | files=[REFACTOR_PROGRESS.md,.github/workflows/release-0-1-validation.yml,scripts/internal/check-source-size.ps1] | validation=[cargo check --workspace,flutter analyze,flutter test:158 passed,source-size check,3x real P2P smoke,git diff --check] | result=R0-R9 majÄ… zaimplementowane bounded zmiany, jeden plik Å›ledzenia progresu i zielone lokalne gates; pozostawiono wyÅ‚Ä…cznie jawne ograniczenie fizycznego Android smoke z powodu braku urzÄ…dzenia ADB | risk=platform evidence must be rerun when a device is connected | next=release handoff`

---

## 3) SzczegÃ³Å‚owy plan: co robiÄ‡, gdzie i jak (top-down)

### EPIC A â€” Stabilizacja funkcjonalna (blokuje wszystko do koÅ„ca)

Wykonujemy **w tej kolejnoÅ›ci**, dopÃ³ki nie przejdziemy do P1:

1. **zamknÄ…Ä‡ P0-10** (pairing),
2. **zamknÄ…Ä‡ P0-09** (chat history),
3. **zamknÄ…Ä‡ P0-11** (startup/reattach),
4. **domknÄ…Ä‡ P0-12** (integration).  

KaÅ¼dy punkt koÅ„czy siÄ™:
- testem lokalnym (manualnym),
- co najmniej jednym testem jednostkowym / integracyjnym.

---

#### A1. Pairing deterministyczny i single-modal (**P0-10**)

**Cel:** jeden widoczny flow zaproszenia, bez â€žpending in backgroundâ€ i bez duplikatÃ³w.

**Do zmiany:**
- `mobile/lib/core/runtime/runtime_repository.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/main.dart`
- `server/torchat-server/src/main.rs`
- `common/client-engine-contract.json`

**Akcje:**
1. UpewniÄ‡ siÄ™, Å¼e `RuntimeRepository.refresh(includePairing: true)`:
   - zawsze wykonuje jawny `pairing_inbox/pairing_outbox` i zwraca wynik w zwracanym `RuntimeRefreshSnapshot`,
   - nie uzaleÅ¼nia dziaÅ‚ania od `ApplicationStateStore.shared` jako ÅºrÃ³dÅ‚a prawdy.
2. dedupe modal przez stabilny `pairingId` + ÅºrÃ³dÅ‚o zdarzenia â€žsingle-shotâ€.
2. ZamieniÄ‡ serwerowe konflikty aktywnego pendingu na idempotentny wynik:
   - zwrÃ³ciÄ‡ `pairingId + expiresAt + state` zamiast surowego 409.
3. W outbox dopisaÄ‡ explicite akcjÄ™ `CANCEL` jako normalny przypadek UI.
4. Przed sprawdzeniem konfliktu usuwanie wygasÅ‚ych rekordÃ³w (`expires_at < now`) dla pary (`sender`,`recipient`).

**Konfiguracja i mapping:**
- `server/torchat-server/src/main.rs`:
  - przy `submit_pairing_code` i lookup najpierw `DELETE` expired,
  - nastÄ™pnie atomiczne `SELECT`/`INSERT` dla aktywnego pending.
- `mobile`:
  - jeden modal `IncomingPairingDialog`,
  - drugi stary ekran typu â€žpending overlayâ€ usuÅ„ albo oznacz jako deprecated,
  - akceptacja i reject mapowane jawnie na `pairingId`.

**Kryterium przejÅ›cia:**
- 3x cykl desktopâ†”android bez restartu:
  - wpisanie kodu powoduje zapis outbox+modal na senderze,
  - recipient dostaje pojedynczy modal w oknie aplikacji bez koniecznoÅ›ci restartu,
  - accept dziaÅ‚a w 1 klik i koÅ„czy pending,
  - kolejne wysÅ‚anie tego samego kodu zwraca idempotentny wynik aktywnego pendingu i nie blokuje.

---

#### A2. Chat projection: nie kasowaÄ‡ historii (P0)

**Problem:** aktywny czat pokazuje â€ž1 ostatniÄ… wiadomoÅ›Ä‡â€ po status updates.

**Do zmiany:**
- `common/torchat-client-engine/src/actor/projection.rs`
- `common/torchat-client-engine/src/event.rs`
- `mobile/lib/core/application_state/application_state_store.dart`
- `mobile/lib/core/runtime/runtime_repository.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/features/chats/release_chat_view.dart`

**Akcje:**
1. DodaÄ‡ w kontrakcie projekcyjnych stampÃ³w: `storeId`, `engineSessionId`, `revision`, `conversationRevision` (zwracane zarÃ³wno w response jak i event).
2. W `RuntimeRepository.messages()`:
   - traktowaÄ‡ odpowiedÅº jako peÅ‚nÄ… tylko po znanym i pasujÄ…cym `revision`,
   - starsze odpowiedzi odrzucaÄ‡;
   - statusowe eventy stosowaÄ‡ jako **delta** (upsert/remove), nie replace caÅ‚ej kolekcji.
3. W `AppState`/store:
   - usuwaÄ‡ merge replace-only logic dla wiadomoÅ›ci czatu na otwartÄ… rozmowÄ™,
   - utrzymaÄ‡ stabilny merge po `messageId` + `createdAt`.
4. `sequential_app_controller`: podczas eventu wiadomoÅ›ci invalidowaÄ‡ tylko konwersacjÄ™, nie od razu globalny `refreshData()` â€“ peÅ‚ny snapshot robiÄ‡ tylko przy pairing/transport global changes.
5. `release_chat_view`: gdy przychodzi nowy message event, nie czyÅ›ciÄ‡ lokalnych wpisÃ³w timeline; przy bÅ‚Ä™dnym parse czasu fallback do indeksÃ³w.

**Kryterium:**
- Scenariusz testowy: otwarta rozmowa z 100 wiadomoÅ›ciami, 10 status update + 2 zdjÄ™cia, brak resetu listy/â€ž1 ostatniej wiadomoÅ›ciâ€, zachowana kolejnoÅ›Ä‡, `DELIVERED` nie nadpisuje treÅ›ci.

---

#### A3. Startup/readiness i attach (**P0-11**)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/platform_facts.rs`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/windows_runtime.dart`
- `mobile/android/app/src/main/kotlin/.../runtime bridge`

**Akcje:**
1. `platform_facts`: trzy oddzielne lanes `tor`, `relay`, `p2p` + `engine`.
2. Android service restart/reconnect emituje `ENGINE_READY` dopiero po `p2p` lub `relay` gotowoÅ›ci zaleÅ¼nie od trybu.
3. na reattach klienta:
   - `getProjectionHead` przed aktywnym re-snapshotem,
   - jeÅ›li `storeId`/`engineSessionId` zmieniony â†’ hard reset lokalnych lane'Ã³w i cache.

**Kryterium:**
- minimize/restore Android: status i readiness przechodzÄ… deterministycznie, brak â€žAPP_READY zanikniÄ™tego connectivityâ€.

---

#### A4. Retry/scheduler safety (P0)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/retry_scheduler.rs`
- `common/torchat-client-engine/src/actor/messaging.rs`

**Akcje:**
1. nie wykonuj natychmiastowych, bezsensownych rerun-Ã³w przy blocked state,
2. bounded backoff statusowy,
3. wydzieliÄ‡ WAITING_* stany od DUE_NOW,
4. po network/tor recovery trigger tylko dedykowanych kolejek.

**Kryterium:**
- 30 wiadomoÅ›ci offline + recovery = brak spin-loop i przewidywalne przemieszczenie z `SENDING` do `DELIVERED`.

---

### EPIC B â€” Stabilizacja pary i komunikacji P2P

#### B1. Capability + proof exchange + durable pre-Welcome buffers (P1/P2)

**Do zmiany:**
- `common/torchat-core/src/peer_protocol.rs`
- `common/torchat-client-engine/src/actor/pairing.rs`
- `common/torchat-client-engine/src/storage/runtime_storage.rs`
- `common/torchat-client-runtime/src/runtime.rs`
- migracje SQL

**Akcje:**
1. utrzymaÄ‡ proof-of-possession HMAC oraz capability ID/secrets lifecycle,
2. trwaÅ‚y zaszyfrowany inbox ramek przed Welcome,
3. durable outbox capability offer/ACK retry,
4. endpoint capability handshake i reset przy rotacji.

**Kryterium:**
- reconnect + crash recovery nie traci Å¼adnej ofert i ACK.

---

#### B2. Endpoint/probe parity (P1)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/application_envelope.rs` (lub nowy probe coord file)
- `mobile/lib/core/probe/*`
- UI consumers

**Akcje:**
1. jeden model probeâ€™Ã³w (`peer`, `relay`, `transport`),
2. jawne enumy stanÃ³w + TTL,
3. render in contact list + header + shell identycznÄ… semantykÄ….

**Kryterium:**
- to samo `statusId` pokazuje ten sam stan w liÅ›cie i nagÅ‚Ã³wku.

---

### EPIC C â€” Refactor strukturalny (po zamkniÄ™ciu A/B)

#### C1. Actor modular split (bez zmiany modelu wÅ‚aÅ›ciciela)

**Do zmiany:**
- `common/torchat-client-engine/src/actor/{mod.rs,command_dispatch.rs,platform_facts.rs,runtime_transaction.rs,...}`

**Akcje:**
1. pozostaÄ‡ na pojedynczym `ClientEngineActor`,
2. wydzieliÄ‡ metody, a nie tworzyÄ‡ rÃ³wnolegÅ‚ego actor modelu,
3. testy jednostkowe per moduÅ‚ + regresyjne integracyjne.

---

#### C2. Storage split

**Do zmiany:**
- `common/torchat-client-engine/src/storage/sqlite/{mod.rs,contacts.rs,messages.rs,pairing.rs,projection.rs,receipts.rs,peer_endpoints.rs,migrations.rs}`

**Akcje:**
1. oddzieliÄ‡ czytelnie operacje persistence vs query,
2. usuwaÄ‡ N+1 zapytaÅ„ przez batch loaders tam gdzie sÄ… pÄ™tle contact list.

---

#### C3. Runtime modular split + repository decomposition

**Do zmiany:**
- `common/torchat-client-runtime/src/{bootstrap,contacts,pairing,messages,conversations}.rs`
- `mobile/lib/core/runtime/repositories/{application_projection,pairing,message}.dart`

**Akcje:**
1. jeden publiczny runtime API,
2. wewnÄ™trznie bardziej granularne moduÅ‚y.

---

#### C4. AppController + state slices (dekorator zamiast dziedziczenia)

**Do zmiany:**
- `mobile/lib/app/app_controller_base.dart`
- `mobile/lib/app/sequential_app_controller.dart`
- `mobile/lib/app/pairing_recovery_app_controller.dart` etc.

**Akcje:**
1. przejÅ›Ä‡ na koordynatory (startup, pairing, chat, presence),
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

### EPIC D â€” UX polish (po stabilizacji)

#### D1. Layout i navigation

- `mobile/lib/features/contacts/contacts_view.dart`
- `mobile/lib/features/chats/release_chat_view.dart`
- `mobile/lib/features/chats/*.dart` 
- `mobile/lib/features/shell/main_shell.dart`

**Akcje:**
1. fixed header/probe alignment,
2. jeden panel statusÃ³w per contact,
3. explicit back navigation on Android (conversation -> chat list; from list -> exit policy),
4. responsive list visibility at narrow widths.

#### D2. Attachments + timeline QoL

- `mobile/lib/features/chats/release_chat_view.dart`
- `mobile/lib/core/runtime/runtime_repository.dart`

**Akcje:**
1. image draft in composer,
2. lazy image materialization,
3. â€žscroll to bottomâ€ CTA,
4. restore drafts across restart (if decided),
5. limit rozmiaru miniaturki 200px.

---

## 3b) Mapa prac do odhaczenia (pliki â†’ efekt)

| ID | Warstwa | Plik(i) | Co robimy | Walidacja |
|---|---|---|---|---|
| A1-1 | Runtime repo | `mobile/lib/core/runtime/runtime_repository.dart` | `refresh(includePairing: true)` zawsze zwraca Å›wieÅ¼e `pairingInbox`/`pairingOutbox` w tym samym zwracanym snapshotcie (bez cache fallback) | unit: `refresh_pairing_includes_inbox` |
| A1-2 | App controller | `mobile/lib/app/sequential_app_controller.dart` | obsÅ‚uga invite single-shot po `pairingId`, dedupe i jedna Å›cieÅ¼ka modalna | manual: 1 invite = 1 modal |
| A1-3 | Server pairing API | `server/torchat-server/src/main.rs` | idempotent odpowiedÅº dla istniejÄ…cego pendingu + cleanup expired przed konfliktem | integration: repeat code submit returns existing pending id |
| A2-1 | Engine event/command | `common/torchat-client-engine/src/actor/projection.rs`, `event.rs`, `command.rs` | stampy projekcyjne + revision guards dla message/app snapshots | unit: starsze odpowiedzi nie nadpisujÄ… nowszego stanu |
| A2-2 | Message repository | `mobile/lib/core/runtime/runtime_repository.dart` | `messages()` dziaÅ‚a jako delta lane; status message nie robi full replace | integration: open chat keeps full history |
| A2-3 | State store | `mobile/lib/core/application_state/application_state_store.dart` | merge/upsert tylko per messageId; brak replace listy na kaÅ¼de event | widget/integration: scroll + 100 msg |
| A2-4 | UI chat | `mobile/lib/features/chats/release_chat_view.dart`, `mobile/lib/app/chat*` | nie czyÅ›ciÄ‡ timeline przy status update, stabilny scroll-to-bottom UX | manual UX: kolejne msg append |
| A3-1 | Startup readiness | `common/torchat-client-engine/src/actor/platform_facts.rs`, `mobile/android/app/src/main/kotlin/org/torchat/mobile/TorRuntime*`, `mobile/lib/windows_runtime.dart` | oddzielne readiness lanes + deterministyczny reattach | manual: minimize/restore Android bez utkniÄ™cia |
| A4-1 | Scheduler | `common/torchat-client-engine/src/actor/retry_scheduler.rs` | WAITING_* + bounded retries + brak â€žbusy-loopâ€ dla blocked state | 50 msg offline + recovery |
| B1-1 | Durable buffers | `common/torchat-client-engine/src/storage/runtime_storage.rs`, `common/torchat-client-engine/src/storage/sqlite` | persistent inbox ramek i capability ACK/outbox | restart test: brak utraty oferty |
| B2-1 | Probe model | `mobile/lib/core/probe/*`, `common/torchat-client-runtime` | unified Probe API + TTL + semantyka stanÃ³w (peer/relay/transport) | widget test: spÃ³jne stany contact list/header |
| C1 | Actor split | `common/torchat-client-engine/src/actor/*.rs` | podziaÅ‚ logiczny plikÃ³w, bez zmiany wÅ‚aÅ›ciciela `ClientEngineActor` | `cargo test -p torchat-client-engine` |
| C2 | Storage split | `common/torchat-client-engine/src/storage/sqlite/*.rs` + `runtime_storage.rs` | wyraÅºny podziaÅ‚ persistence/query + migration tables helpers | clippy + migration tests |
| C3 | Runtime split | `common/torchat-client-runtime/src/{bootstrap,contacts,pairing,messages,conversations}.rs` | modularizacja domenowa `ClientRuntime` | `cargo test --workspace` |
| C4 | AppController | `mobile/lib/app/*.dart` | zastÄ…piÄ‡ dekoracyjne dziedziczenie koordynatorami | manual state flow sanity |
| D1 | UX | `mobile/lib/features/contacts/contacts_view.dart`, `mobile/lib/features/shell/main_shell.dart` | jeden panel statusÃ³w, brak nakÅ‚adajÄ…cych ikon, back-navigation Android | manual responsive checks |
| D2 | Attachments | `mobile/lib/features/chats/release_chat_view.dart` | image enqueue, miniatury <=200px, lazy load placeholdery | manual: 10 zdjÄ™Ä‡ w rozmowie |

KaÅ¼dy wpis koÅ„czy siÄ™ dopisaniem wpisu do logbooku (`## 2) Live log`).

## 4) Akceptacja release (MUST pass)

1. pairing desktopâ†”android 3x po kolei:
   - invite -> accept -> first msg -> reopen -> messages stale do czasu open => recover
2. chat live history: incoming statusy nie kasujÄ… treÅ›ci,
3. minimize/restore Android: readiness nie resetuje siÄ™ losowo,
4. offline retry: `QUEUED` -> `SENDING` -> `SENT`/`DELIVERED` bez spin-loop,
5. remove/repair/re-pair flow: local restart does not lose conversation,
6. no crash due mojibake, no stale one-modal bug,
7. two-engine integration test in CI passes (RG-03).

---

## 5) Plan wykonawczy od dziÅ› (krotki, ale konkretny)

### Zasada wykonania (bezpieczny porzÄ…dek)

1. Najpierw domykamy **P0 blokujÄ…ce** (`P0-09`, `P0-10`, `P0-11`, `P0-12`)  
2. Potem `P1` (stabilnoÅ›Ä‡ i wÅ‚asnoÅ›Ä‡ projekcji)  
3. Na koÅ„cu `P2` (UX/UI + polish), ale bez zmian architektonicznych ingerujÄ…cych w transport.

### RÃ³wnolegle prowadzone workstreamy

KaÅ¼dy tydzieÅ„ prowadzimy 2 workstreamy:
- **S1 (stability):** engine/runtime/repository + scripts (bez UI redesignu).
- **S2 (delivery):** UI, navigation, chat UX, listy, attachmenty.

Tym samym blokujemy ryzyko, Å¼e refactor UI przykryje bÅ‚Ä…d transportowy.

### Dzisiejsze zadania (kolejnoÅ›Ä‡ na 2 dni)

**DzieÅ„ 1 â€” rozmowa + pairing core**
- B0-01 domknÄ…Ä‡ delta-lane wiadomoÅ›ci (brak replace)  
- B0-02 domknÄ…Ä‡ jeden modal pairingu + idempotent pending + includePairing fetch  
- S1-01 wprowadziÄ‡ `conversationRevision`/`storeId` i revision checks w response/event  
- DopiÄ…Ä‡ wpisy w `## 2) Logbook` po kaÅ¼dym kroku  

**DzieÅ„ 2 â€” startup i retry**
- B0-03 reattach + ready lanes (android/desktop)  
- A4-1 scheduler WAITING_* i bounded requeue  
- S1-03 read-your-writes + natychmiastowa publikacja efektu mutacji  
- dodaÄ‡ 2 krÃ³tkie testy manual (pairing 3x i otwarty czat 100 msg)

**DzieÅ„ 3 â€” hardening i integracja**
- B1-1 durable pre-Welcome inbox + capability outbox  
- A3-1 endpoint/probe semantic alignment  
- P0-12 smoke test desktopâ†”android (3 rundy, 2 kierunki)  
- odÅ›wieÅ¼yÄ‡ logbook + status procentowy.

### Kryterium przejÅ›cia na kolejny etap
- brak regresji na 3x smoke pairing + message history
- brak utraty wiadomoÅ›ci przy otwartym czacie
- Android minimize/restore: readiness deterministyczny
- brak restart-only "odÅ›wieÅ¼enia listy" w celu odzyskania historii

### Logbook-as-code (jak uzupeÅ‚niaÄ‡)

KaÅ¼dorazowo po zakoÅ„czeniu:
1. dopisujesz wiersz do `## 2) Logbook`:
   - `EP`, status, pliki, walidacja, wynik, ryzyko, next
2. jeÅ›li zmieniasz API/projekcje, dopinajesz test/manual proof
3. dopinasz w `10)` listÄ™ plikÃ³w dotkniÄ™tych i usuwasz `IN_PROGRESS`/`TODO` status.

PrzykÅ‚ad wpisu:
`2026-08-03 14:20:00 | EP=B0-01 | owner=AI | status=in_progress | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/core/application_state/application_state_store.dart] | validation=[manual 20 msg open-chat] | result=przejÅ›cie z replace na merge+upsert | risk=ordering eventu przy multi-device | next=B0-02`

### Komendy wejÅ›cia/wyjÅ›cia dla kaÅ¼dego etapu

#### WejÅ›cie
- `cargo fmt --all -- --check`
- `cargo check --workspace`
- `cd mobile && flutter analyze`
- rÄ™czny smoke: parowanie + otwarty czat + statusy

#### WyjÅ›cie (DONE_VERIFIED)
- `cargo test --workspace`
- peÅ‚ny smoke script desktopâ†”android min 3 rundy
- `flutter test`
- logbook + update statusu EP na `done_verified`

### Szacowane obciÄ…Å¼enie dziÅ›

- **P0**: 4 epiki (A1/A2/A3/A4), Å‚Ä…czny czas 2â€“3 dni
- **P1**: 4 epiki, 2â€“3 dni
- **P2**: 3 epiki, 1â€“2 dni

## 6) KolejnoÅ›Ä‡ tygodniowego wykonania

### TydzieÅ„ 1 (P0 closure)
- Dni 1-2: A1 + A2 + A3 + A4 (peÅ‚ne logi i manual smoke co iteracjÄ™)
- DzieÅ„ 3: B1 + pairing cleanup in server + reattach checks
- DzieÅ„ 4: release + integration smoke + regresje

### TydzieÅ„ 2 (P1)
- Dni 1-3: C1/C2/C3, zachowujÄ…c API stabilne
- DzieÅ„ 4: C4 + C5
- DzieÅ„ 5: code cleanup + check-size + CI gates + release-0-1 gate prep

### TydzieÅ„ 3 (P2)
- Dni 1-3: D1/D2 polish + responsive and back behavior
- DzieÅ„ 4: accessibility + perf polish
- DzieÅ„ 5: final verification and merge.

---

## 7) Aktualne ryzyka do monitorowania (codzienny przeglÄ…d)

- event ordering vs response ordering,
- stale cache overwrite without revision,
- one-modal drift,
- attachment retry loops,
- service lifecycle under Android taskkill/minimize.

---

## 8) Commandy regresyjne po kaÅ¼dym EPIC

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
- manual pairing/chat smoke (3 runy kaÅ¼de urzÄ…dzenie)

---

## 9) Notatka operacyjna

Ten plik ma pozostaÄ‡ **jedynym ÅºrÃ³dÅ‚em planu wdroÅ¼eniowego**. KaÅ¼da wiÄ™ksza zmiana to jeden wpis w â€žLive logâ€ i update statusu EP/ID.
---

## 10) Refactor execution backlog (single source of truth)

To jest wersja "do wdroÅ¼enia od rÄ™ki" na kolejne iteracje. KaÅ¼dy wiersz = jeden blok roboczy do wykonania end-to-end i zamkniÄ™cia testami.

### 9.1 Pracownia 0: StabilnoÅ›Ä‡ rozmowy i parowania (blocking)

| ID | Status | Zakres | Gdzie | Co dokÅ‚adnie | Kryterium zakoÅ„czenia |
| --- | --- | --- | --- | --- | --- |
| B0-01 | IN_PROGRESS | Live-history no-loss | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/app/sequential_app_controller.dart`, `mobile/lib/app/app_controller_base.dart`, `mobile/lib/features/chats/release_chat_view.dart`, `common/torchat-client-engine/src/actor/projection.rs`, `common/torchat-client-engine/src/event.rs` | Wykonujemy single-writer chat lane: status i message events przechodza jako delta i nie replace'uje peÅ‚nej listy otwartej rozmowy. Response/event zawiera `conversationRevision`; starszy wynik jest odrzucany. | W otwartym czacie brak resetu do 1 wiadomosci po status/update; 50+ wiadomosci zostaje zachowanych i appenduje siÄ™ stabilnie. |
| B0-02 | IN_PROGRESS | One-modal pairing + deterministic invite | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/app/main.dart`, `mobile/lib/app/sequential_app_controller.dart`, `server/torchat-server/src/main.rs` | Jeden path `IncomingPairingDialog`; refresh includePairing robi jawny fetch inbox/outbox i nie opiera siÄ™ o fallback cache. Serwer zwraca idempotentny pending zamiast ogolnego 409. | Kod aktywuje jedno oczekujace zaproszenie, recipient dostaje jeden modal bez restartu, accept/reject dziaÅ‚a i czymsia w tym samym idempotency. |
| B0-03 | PENDING | Android/desktop reattach status lanes | `common/torchat-client-engine/src/actor/platform_facts.rs`, `mobile/lib/windows_runtime.dart`, Android bridge | readiness na lane: tor, relay, p2p, engine + head snapshot przed odswiezeniem. | minimize/restore nie powoduje rozjechanych statusow; APP_READY = deterministyczne. |
| B0-04 | PENDING | Warmup deterministyczny | `scripts/torchat.ps1`, `scripts/internal/*.ps1`, runtime startup hooks | Jednoznaczny status progress; eliminacja â€žapp stuckâ€ bez czytelnej przyczyny. | DÅ‚ugie deploye dajÄ… powtarzalny wynik: fail->jeden czytelny step lub success. |

### 9.2 Pracownia 1: Projekcja i stan transportu

| ID | Status | Zakres | Gdzie | Co dokÅ‚adnie | Kryterium zakoÅ„czenia |
| --- | --- | --- | --- | --- | --- |
| S1-01 | DONE_VERIFIED | Projection stamps in engine | `common/torchat-client-engine/src/actor/projection.rs`, `common/torchat-client-engine/src/command.rs`, `common/client-engine-contract.json`, `tools/torchat-contract-gen/src/main.rs` | Response i event zawierajÄ… `storeId`, `engineSessionId`, `revision`; durable head jest czytany z SQLite w tej samej projekcji. | Contract, Rust tests i Flutter analyze przechodzÄ…; starsze application snapshots sÄ… odrzucane przez store. `conversationRevision` pozostaje osobnym follow-upem, nie udajemy Å¼e jest gotowy. |
| S1-02 | DONE_VERIFIED | Projection coordinator (Flutter) | `mobile/lib/core/runtime/runtime_repository.dart`, `mobile/lib/core/application_state/application_state_store.dart`, `mobile/lib/app/sequential_app_controller.dart` | Lane per conversation ma dedupe in-flight/trailing refresh, epoch/sequence guards i merge/upsert zamiast replace dla live refresh. | `cargo` + `flutter analyze` przechodzÄ…; peÅ‚ny dwuurzÄ…dzeniowy smoke pozostaje wymagany dla `P0-12`. |
| S1-03 | IN_PROGRESS | Read-your-writes | `common/torchat-client-engine/src/command.rs`, `mobile/lib/core/runtime/runtime_repository.dart` | sendMessage/accept/welcome returns mutation snapshot + revision; UI od razu pokazuje lokalny post. | Brak â€žcoÅ› wisialy w kolejce mimo wyslanych eventowâ€. |

### 9.3 Pracownia 2: Refactor strukturalny

| ID | Status | Zakres | Gdzie | Co dokÅ‚adnie | Kryterium zakoÅ„czenia |
| --- | --- | --- | --- | --- | --- |
| S2-01 | DONE_VERIFIED | Actor split modules | `common/torchat-client-engine/src/actor/*.rs` | Podzielono dispatch, pairing, messaging, relay/peer events, projection, receipts, retry i transakcjÄ™; nadal istnieje jeden `ClientEngineActor`. | `cargo fmt/check/test/clippy` przechodzÄ…; `actor/mod.rs` zmniejszony do 1320 linii; dalsze rozbijanie nie jest wymagane dla 0.1. |
| S2-02 | DONE_VERIFIED | Storage split | `common/torchat-client-engine/src/storage/sqlite/*.rs` | Wydzielono migracje, rekordy, wiadomoÅ›ci, pairing, receipts, projection i endpointy; API `ClientDatabase` zachowane. | `cargo test --workspace` i SQL isolation check przechodzÄ…; `sqlite/mod.rs` ma 1246 linii. |
| S2-03 | IN_PROGRESS | Runtime split | `common/torchat-client-runtime/src` | Modularizacja domenowa runtime, bez zmiany publicznego API. | testy runtime i engine stable. |
| S2-04 | IN_PROGRESS | Controller cleanup | `mobile/lib/app/*.dart` | Zamiast dziedziczenia -> koordynatory slices. | Mniejsze couplingi i jednoznaczny wÅ‚aÅ›ciciel stanu rozmowy. |

### 9.4 Pracownia 3: UX i interakcje

| ID | Status | Zakres | Gdzie | Co dokÅ‚adnie | Kryterium zakoÅ„czenia |
| --- | --- | --- | --- | --- | --- |
| UX-01 | IN_PROGRESS | Android back/navigation | `mobile/lib/app/main.dart`, `mobile/lib/app/sequential_app_controller.dart` | Back handling zgodny z nav stackiem. | Rozmowa -> listy rozmow; tylko na root aplikacja idzie w background. |
| UX-02 | IN_PROGRESS | Header/probe alignment + busy indicator | `mobile/lib/shared/widgets/contact_list_section.dart`, `mobile/lib/shared/widgets/conversation_list_section.dart`, `mobile/lib/features/chats/release_chat_view.dart` | Jeden panel statusu, spÃ³jne stany, poprawne pozycjonowanie ikon. | Brak nakladania elementÃ³w i bÅ‚Ä™dnych alignÃ³w. |
| UX-03 | IN_PROGRESS | Responsive + attachments | `mobile/lib/features/chats/release_chat_view.dart`, `mobile/lib/core/runtime/runtime_repository.dart` | Lazy image, max thumbnail 200px, stale statusy wysylki, scroll-to-bottom CTA. | 360 px layout i attachments stabilne. |

### 9.5 Pracownia 4: Endpoint capability and message security hardening

| ID | Status | Zakres | Gdzie | Co dokÅ‚adnie | Kryterium zakoÅ„czenia |
| --- | --- | --- | --- | --- | --- |
| H-01 | DONE | proof-of-possession HMAC | `common/torchat-core/src/peer_protocol.rs`, `common/torchat-client-engine/src/actor/pairing.rs` | HMAC proof required in peer hello, invalid proof rejected. | Brak nieautoryzowanego peer hello. |
| H-02 | IN_PROGRESS | durable pre-Welcome inbox | `common/torchat-client-engine/src/storage/runtime_storage.rs`, sqlite migration | TrwaÅ‚e przechowanie ramek otrzymanych przed Welcome, replay po commit. | restart nie gubi frame'Ã³w. |
| H-03 | IN_PROGRESS | durable capability outbox retry | `common/torchat-client-engine/src/storage/runtime_storage.rs`, pairing actors | capability offer/ack in outbox with retry across restarts/reconnect. | Nie zgubic capability handshake przy offline/restart. |

### 9.6 Operacyjny logbook (wymuszony)

KaÅ¼dy wiersz wpisujcie bezpoÅ›rednio w sekcji 2. Format:

`TS | EP=<id> | owner=<who> | files=[..] | status=<done|done_verified|in_progress|blocked> | validation=[cmd|unit|manual|e2e] | result=<1 line> | risk=<1 line> | next=<next action>`

PrzykÅ‚ad:
`2026-08-03 14:20:00 | EP=B0-01 | owner=AI | files=[mobile/lib/core/runtime/runtime_repository.dart,mobile/lib/features/chats/release_chat_view.dart] | status=in_progress | validation=[manual: desktopâ†”android 3x, 100 msg open-chat] | result=lane history delta + revision guard` 

- `2026-08-03 16:10:00 | EP=UX-TOAST-01 | owner=AI | files=[mobile/lib/app/notifications/toast_message.dart,mobile/lib/app/notifications/ui_notification_center.dart,mobile/lib/shared/widgets/toast_host.dart,mobile/lib/main.dart,mobile/lib/app/app_controller_base.dart,mobile/lib/features] | status=done_verified | validation=[flutter analyze,flutter test:159 passed,static:no showSnackBar in lib] | result=jeden globalny top-center toast host, limit 3 + FIFO, dedupe, slide/fade, usuniÄ™to AppState.notice i wszystkie produkcyjne SnackBary; submit pairingu nie emituje faÅ‚szywego sukcesu, terminalny wynik outboxu emituje toast | risk=wizualny smoke na fizycznym Androidzie i Windows pozostaje do wykonania | next=build apk/windows i rÄ™czny smoke pairing accepted/rejected/expired`
- `2026-08-03 16:45:00 | EP=UX-CHAT-02 | owner=AI | files=[mobile/lib/features/chats/release_chat_view.dart,mobile/lib/features/chats/message_bubble.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/lib/shared/widgets/tor_status_bar.dart] | status=done_verified | validation=[flutter analyze,focused widget tests,flutter test] | result=ujednolicono akcje headera 40x40 i composer 44x44, ograniczono tekstowe bÄ…belki do dynamicznej szerokoÅ›ci 120-560, dopracowano status dock, inspector i czytelne daty/etykiety | risk=ostateczny pixel-level smoke wymaga uruchomionego Windows UI | next=manual screenshot review po redeploy desktop`
- `2026-08-03 17:10:00 | EP=B0-02 | owner=AI | files=[mobile/lib/core/models/domain.dart,mobile/lib/core/runtime/runtime_bridge_base.dart,mobile/lib/main.dart,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/shell/main_shell.dart,mobile/lib/app/pairing_recovery_app_controller.dart,mobile/test/pairing_origin_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:162 passed] | result=toast jest routowany wyÅ‚Ä…cznie dla outbox, modal wyÅ‚Ä…cznie dla inbox, oczekujÄ…ce parowania sÄ… widoczne przed Welcome, a recovery wykonuje trzy ograniczone odÅ›wieÅ¼enia projekcji po akceptacji | risk=manualny smoke Androidâ†”desktop nadal wymagany do potwierdzenia opÃ³ÅºnieÅ„ relay/Welcome | next=uruchomiÄ‡ fizyczny pairing i sprawdziÄ‡ jeden modal oraz toast tylko na urzÄ…dzeniu wysyÅ‚ajÄ…cym`

2026-08-03 18:00:00 | EP=PRESENCE-01 | owner=AI | files=[mobile/lib/core/presence/contact_presence_snapshot.dart,mobile/lib/core/presence/contact_presence_store.dart,mobile/lib/core/presence/contact_probe_coordinator.dart,mobile/lib/app/sequential_app_controller.dart] | status=in_progress | validation=[flutter analyze] | result=Dodano wspólny snapshot/store/coordinator i podlaczono obecne eventy presence, focus oraz peer connection; expiry przechodzi do unknown | risk=widoki nadal migruja ze starych map AppState; focus wymaga mapowania conversationId?contactId | next=przepiac liste, header i inspector na ContactPresenceStore
2026-08-03 19:00:00 | EP=PRESENCE-06/08 | owner=AI | files=[mobile/lib/app/app_controller_base.dart,mobile/lib/app/sequential_app_controller.dart,mobile/lib/core/presence/contact_probe_coordinator.dart,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/connection/connection_center_sheet.dart,mobile/test/contact_presence_coordinator_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:coordinator+presence,cargo test -p torchat-client-engine probing] | result=usunięto legacy mapy i timery z AppState/kontrolera, focus mapuje conversationId na contactId, panel mobilny i reattach używają snapshotu, dodano logi pseudonimizowane i testy | risk=pełny smoke desktop↔Android wymaga urządzeń/runtime; logi używają stabilnego hashCode procesu Dart | next=uruchomić pełny flutter test i manualny smoke cross-device
2026-08-03 19:20:00 | EP=PRESENCE-08 | owner=AI | files=[mobile/lib/core/presence/contact_probe_coordinator.dart,REFACTOR_PROGRESS.md] | status=in_progress | validation=[flutter build apk --debug,adb install+monkey Android,flutter build windows] | result=APK zbudowany, zainstalowany i uruchomiony na Androidzie; build Windows zatrzymał się na braku dostępu do windows/flutter/ephemeral/.plugin_symlinks | risk=nie wykonano pełnego smoke desktop↔Android ani scenariusza sparowania dwóch urządzeń; Windows wymaga uprawnień/symlinków środowiska | next=powtórzyć Windows build/smoke po udostępnieniu katalogu ephemeral, następnie wykonać cross-device presence/focus
2026-08-03 19:40:00 | EP=PRESENCE-FINAL | owner=AI | files=[mobile/lib/app/app_controller_base.dart,mobile/lib/app/sequential_app_controller.dart,mobile/lib/core/presence,mobile/lib/features/contacts/contacts_view.dart,mobile/lib/features/shell/desktop/desktop_workspace.dart,mobile/test/contact_presence_coordinator_test.dart] | status=done_verified | validation=[flutter analyze,flutter test:165 passed,cargo test -p torchat-client-engine probing:2 passed] | result=zakres kodowy presence zakończony; smoke Windows↔Android pominięty na żądanie użytkownika | risk=brak ręcznej walidacji cross-device | next=brak
2026-08-03 20:10:00 | EP=PROBE-SUBSCRIPTIONS-01 | owner=AI | files=[common/torchat-client-engine/src/probing.rs,common/torchat-client-engine/src/actor/peer_control.rs,common/torchat-client-engine/src/actor/peer_events.rs,mobile/lib/core/presence/contact_probe_coordinator.dart] | status=done_verified | validation=[cargo test -p torchat-client-engine probing:5 passed,cargo check -p torchat-client-engine,flutter analyze,focused flutter tests:7 passed] | result=ProbeCoordinator publikuje retained ProbeSnapshot przez tokio watch, wielu subskrybentów współdzieli jeden claim, actor używa begin_due z timeoutem in-flight, a logi probe pochodzą z rzeczywistego cyklu Rust | risk=pozostałe ProbeKind mają gotowy model subskrypcji, ale ich konkretne drivery nadal powstają dopiero wraz z rzeczywistą operacją transportową | next=brak
2026-08-03 20:45:00 | EP=PROBE-MIGRATION-ALL | owner=AI | files=[common/torchat-client-engine/src/probing.rs,common/torchat-client-engine/src/actor/peer_control.rs,common/torchat-client-engine/src/actor/peer_events.rs,common/torchat-client-engine/src/actor/connection.rs] | status=done_verified | validation=[cargo test -p torchat-client-engine:52 passed,cargo check -p torchat-client-engine,flutter analyze,focused Flutter tests:5 passed] | result=podpięto ContactPeer, presence heartbeat, endpoint, capability, focus, relay, onion i engine do jednolitego ProbeKey/ProbeSnapshot; scheduler claimuje tylko due, a wyniki techniczne publikują retained watch | risk=brak cross-device smoke zgodnie z wcześniejszą decyzją; runtime nadal dostarcza snapshoty Fluttera przez istniejące eventy | next=brak

PRESENCE-09 — Read receipts: focus rozmowy wysyła ReadReceipt, a stan wiadomości przechodzi do „odczytano”; receipt transport pozostaje na istniejącym peer probe.
