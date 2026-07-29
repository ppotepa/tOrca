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
- [x] Usuniety warning `dead_code` z desktop przez skasowanie nieuzywanego `identity_store::load_existing`.
- [x] Usuniete warningi Cargo o hardlinkach incremental przez repo-local `.cargo/config.toml` z `incremental = false`.
- [x] Dodane ignorowanie Gradle/Kotlin cache `.kotlin/`.
- [x] CodeGraph zsynchronizowany po zmianach.

## Verification Notes

`cargo test -p torchat-client-engine storage::sqlite::tests` wypisuje log SQLCipher przy tescie z blednym kluczem:

```text
sqlcipher_page_cipher: hmac check failed for pgno=1
sqlite3Codec: error decrypting page 1 data: 1
```

To jest oczekiwane i odpowiada testowi `reopen_with_wrong_sqlcipher_key_fails_integrity_check`.

Oba wyszukania `rg` dla legacy request/response i hardcoded command type zakonczyly sie bez trafien produkcyjnych.

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
flutter analyze lib/core/runtime lib/mobile_bridge.dart lib/windows_runtime.dart lib/client_runtime.dart
.\gradlew.bat :app:compileDebugKotlin
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo check -p torchat-client-engine -p torchat-desktop
$env:PATH='C:\Strawberry\perl\bin;'+$env:PATH; cargo test -p torchat-client-runtime
rg -n "RuntimeRequest|RuntimeResponse|dispatch_runtime|map_runtime_request|response_to_runtime_response" desktop mobile common
rg -n '"type", "[a-z_]+"|put\("type", "[a-z_]+"|''method'': method|''params'': params' mobile desktop common
codegraph sync
```

## Exit Criteria

- [x] Wszystkie punkty z poprzedniego planu w `SUMMARY.MD` sa domkniete.
- [x] Rust engine, Rust FFI, desktop, Flutter i Android maja lokalne potwierdzenie.
- [x] Branch ma byc czysty po finalnym commicie i pushu.
