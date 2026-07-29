# TorChat Refactor Summary

Last updated: 2026-07-29
Branch: `agent/common-runtime-cleanup`
Latest pushed commit: `28c271c Complete engine contract refactor`

## Goal

Domknac refactor zgodnie z `REFACTOR2.MD` i `AGENTS.md`: aktywne legacy sciezki maja zniknac, a Android, desktop, Flutter i Rust maja korzystac z jednego kontraktu engine generowanego z `common/client-engine-contract.json`.

## Current Status

Status ogolny: code refactor jest zaimplementowany i wypchniety, ale nie jest jeszcze w pelni zweryfikowany przez Rust engine/desktop build.

Przechodzi lokalnie:

- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\check-runtime-contract.ps1`
- [x] `powershell -ExecutionPolicy Bypass -File scripts\internal\check-legacy-cleanup.ps1`
- [x] `cargo test -p torchat-client-runtime`
- [x] `flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart`
- [x] `.\gradlew.bat :app:compileDebugKotlin` z katalogu `mobile\android`

Zablokowane lokalnie:

- [ ] `cargo test -p torchat-client-engine storage::sqlite::tests`
- [ ] `cargo test -p torchat-client-engine-ffi c_api::tests`
- [ ] `cargo check -p torchat-client-engine -p torchat-desktop`

Bloker: `openssl-sys` buduje vendored OpenSSL i wymaga `perl`. Na tej maszynie `where perl` nie znajduje Perla.

## Done

- [x] Repo wypchniete na GitHub: `https://github.com/ppotepa/tOrca`
- [x] Branch roboczy wypchniety: `agent/common-runtime-cleanup`
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
- [x] Dodane testy SQLite/SQLCipher w `common/torchat-client-engine/src/storage/sqlite.rs`.
- [x] Dodane testy lifecycle C ABI w `common/torchat-client-engine-ffi/src/c_api.rs`.
- [x] CodeGraph zsynchronizowany po zmianach.

## Remaining Work

### 1. Odblokowac Rust engine build

Cel: umozliwic lokalne wykonanie testow `torchat-client-engine`, `torchat-client-engine-ffi` i desktop check.

Kroki:

- [ ] Zainstalowac Perl dostepny w `PATH`, np. Strawberry Perl na Windows.
- [ ] Potwierdzic:

```powershell
where perl
perl -v
```

- [ ] Ponowic test SQLite:

```powershell
cargo test -p torchat-client-engine storage::sqlite::tests
```

- [ ] Ponowic test FFI:

```powershell
cargo test -p torchat-client-engine-ffi c_api::tests
```

- [ ] Uruchomic targeted build granicy engine/desktop:

```powershell
cargo check -p torchat-client-engine -p torchat-desktop
```

Acceptance:

- [ ] Wszystkie trzy komendy przechodza.
- [ ] Jesli sa bledy kompilacji, poprawic je w kodzie, ponowic tylko relevant command i zaznaczyc tutaj.

### 2. Zweryfikowac testy SQLCipher

Cel: potwierdzic, ze storage engine wymaga poprawnego 32-bajtowego klucza i ze migracje dochodza do wersji `4`.

Symbole/pliki:

- `ClientDatabase::open`
- `sqlcipher_key_pragma`
- `ClientDatabase::migration_runner`
- `MIGRATIONS`
- `common/torchat-client-engine/src/storage/sqlite.rs`
- `common/torchat-client-engine/sql/migrations/003_pairing_response_delivery.sql`
- `common/torchat-client-engine/sql/migrations/004_retry_indexes.sql`

Kroki:

- [ ] Uruchomic:

```powershell
cargo test -p torchat-client-engine storage::sqlite::tests
```

- [ ] Jezeli `reopen_with_wrong_sqlcipher_key_fails_integrity_check` nie przejdzie, sprawdzic faktyczny blad `rusqlite/sqlcipher` i doprecyzowac assertion na `EngineError::Storage`.
- [ ] Jezeli migracje nie dojda do `4`, sprawdzic `MIGRATIONS` i tabele `schema_migrations`.

Acceptance:

- [ ] Test `open_requires_32_byte_database_key` przechodzi.
- [ ] Test `open_runs_all_migrations_with_correct_sqlcipher_key` przechodzi.
- [ ] Test `reopen_with_wrong_sqlcipher_key_fails_integrity_check` przechodzi.

### 3. Zweryfikowac C ABI lifecycle

Cel: potwierdzic, ze nowy `torchat-client-engine-ffi` bezpiecznie obsluguje shutdown/free/poll/submit.

Symbole/pliki:

- `torchat_client_engine_new`
- `torchat_client_engine_shutdown`
- `torchat_client_engine_free`
- `torchat_client_engine_submit_json`
- `torchat_client_engine_poll_json`
- `torchat_client_engine_last_error`
- `common/torchat-client-engine-ffi/src/c_api.rs`

Kroki:

- [ ] Uruchomic:

```powershell
cargo test -p torchat-client-engine-ffi c_api::tests
```

- [ ] Jesli testy wisza, sprawdzic czy `ClientEngine::new()` nie startuje actorow wymagajacych runtime przed `start()`.
- [ ] Jesli test `poll_after_shutdown_returns_empty_json_without_error` pada, sprawdzic, czy shutdown actor wysyla event fatal/shutdown zamiast pustego poll.

Acceptance:

- [ ] `submit_after_shutdown_returns_closed_error` przechodzi.
- [ ] `shutdown_and_free_are_idempotent_before_start` przechodzi.
- [ ] `poll_after_shutdown_returns_empty_json_without_error` przechodzi.

### 4. Zweryfikowac engine/desktop compile

Cel: potwierdzic, ze desktop stdio i engine actor kompiluja sie razem po przejsciu na `EngineCommandEnvelope`/`EngineEvent`.

Symbole/pliki:

- `ClientEngine`
- `ClientEngineActor`
- `EngineCommandEnvelope`
- `EngineCommand`
- `EngineEvent`
- `desktop/src/runtime_engine_stdio.rs`
- `common/torchat-client-engine/src/actor.rs`
- `common/torchat-client-engine/src/engine.rs`

Kroki:

- [ ] Uruchomic:

```powershell
cargo check -p torchat-client-engine -p torchat-desktop
```

- [ ] Jesli bledy dotycza `EngineCommand::Shutdown`, sprawdzic zgodnosc enumow i matchy w:
  - `common/torchat-client-engine/src/actor.rs`
  - `desktop/src/runtime_engine_stdio.rs`
- [ ] Jesli bledy dotycza storage, sprawdzic migracje i nazwy kolumn w:
  - `common/torchat-client-engine/src/storage/sqlite.rs`
  - `common/torchat-client-engine/src/storage/runtime_storage.rs`

Acceptance:

- [ ] `cargo check -p torchat-client-engine -p torchat-desktop` przechodzi.

### 5. Full consistency pass

Cel: po odblokowaniu Rust builda potwierdzic, ze generator, checker i wygenerowane stale sa spojne.

Kroki:

- [ ] Uruchomic contract checker:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\internal\check-runtime-contract.ps1
```

- [ ] Uruchomic legacy checker:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\internal\check-legacy-cleanup.ps1
```

- [ ] Wyszukac pozostalosci starego runtime request/response w produkcyjnych warstwach:

```powershell
rg -n "RuntimeRequest|RuntimeResponse|dispatch_runtime|map_runtime_request|response_to_runtime_response" desktop mobile common
```

- [ ] Wyszukac hardcoded command type poza generated/contract mapper:

```powershell
rg -n '"type", "[a-z_]+"|put\("type", "[a-z_]+"|''method'': method|''params'': params' mobile desktop common
```

Acceptance:

- [ ] Contract checker przechodzi.
- [ ] Legacy checker przechodzi.
- [ ] Brak aktywnych produkcyjnych trafien legacy.
- [ ] Trafienia testowe lub checkerowe sa opisane i celowe.

### 6. Finalny commit po weryfikacji

Cel: zapisac poprawki po odblokowaniu Perla i ewentualnych bledach compile.

Kroki:

- [ ] Sprawdzic status:

```powershell
git status -sb
```

- [ ] Jesli byly poprawki po `28c271c`, zrobic commit:

```powershell
git add -A
git commit -m "Verify engine refactor checks"
git push
```

- [ ] Jesli nie bylo poprawek, tylko zaktualizowac ten plik i wypchnac:

```powershell
git add SUMMARY.MD
git commit -m "Track refactor closure status"
git push
```

Acceptance:

- [ ] `git status -sb` pokazuje czysty branch tracking `origin/agent/common-runtime-cleanup`.
- [ ] GitHub zawiera aktualny `SUMMARY.MD`.

## Commands Log

Ostatnio wykonane i zaliczone:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\internal\check-runtime-contract.ps1
powershell -ExecutionPolicy Bypass -File scripts\internal\check-legacy-cleanup.ps1
cargo test -p torchat-client-runtime
flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart
.\gradlew.bat :app:compileDebugKotlin
codegraph sync
```

Ostatnio wykonane i zablokowane:

```powershell
cargo test -p torchat-client-engine storage::sqlite::tests
cargo test -p torchat-client-engine-ffi c_api::tests
```

Powod: `openssl-sys` -> `Command 'perl' not found`.

