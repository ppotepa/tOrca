# Audyt P2P — 2026-07-30

Audyt wykonano na snapshotcie `ba7011d0f0f871e4d926826350c9104ba4e13263`
oraz na jego bazie `origin/main` (`fee3a1c878f4eb246e5d805df4979160a2822250`).
Poza zakończeniami linii snapshot różnił się od bazy tylko plikiem
`scripts/zip.ps1`; jego treść została zachowana.

## 1. Audyt obecnego stanu

Prześledzono komendy od `common/client-engine-contract.json` przez wygenerowane
stałe Kotlin/Dart, adaptery platformowe i `EngineCommand`. `getPeerEndpoint`,
`retryPeerConnection`, `rotatePeerEndpoint` oraz polityka transportu są obecne
po obu stronach kontraktu. `MainActivity` nie tworzy engine — korzysta z
instancji należącej do `TorChatForegroundService`.

Najważniejsze znalezione przyczyny:

- relay odrzucał `PeerEndpointBootstrap` i zaszyfrowany payload wiadomości,
  mimo że engine wysyła oba typy;
- klient P2P kończył odbiór ACK na `PERSISTED`, więc nie odbierał późniejszego
  `DELIVERED`;
- każde oczekiwanie na frame miało ukryty timeout 5 s, także wewnątrz
  60-sekundowego timeoutu ACK;
- błędy połączeń przychodzących były ignorowane;
- desktop logował pełne wejście/wyjście JSONL, w tym dane aplikacyjne;
- startup Androida i desktopu uruchamiał Tor przed otwarciem engine/storage.

Logi dostarczone w snapshotcie nie zawierają bieżącego
`getPeerEndpoint not found` ani `TorChat Runtime stopped`. Kontenery w ostatnim
runie zostały zatrzymane poprawnie (`exit 0`). Naprawa `Runtime stopped`
rozróżnia teraz oczekiwane zamknięcie sidecara od nieoczekiwanej utraty procesu.

## 2. Sekwencyjny startup

Docelowa kolejność jest teraz inicjowana jako:

1. storage, identity i wspólny engine;
2. lokalny listener P2P;
3. Tor control/SOCKS;
4. onion service wskazujący port listenera;
5. lokalny `PeerEndpointBundle`;
6. relay i kolejki;
7. odblokowanie UI.

Android kolejkuje akcję `configure_onion_service`, dopóki control Tor nie jest
gotowy. Desktop tworzy engine przed `TorRuntime`. Flutter nie przechodzi z ekranu
boot, dopóki wszystkie wymagane kroki nie mają stanu `ready`.

Dodano jawny stan `blocked`: krytyczny błąd oznacza aktywny krok na czerwono,
a późniejsze kroki na ciemnoszaro i nie pozwala kontynuować.

## 3. Statusy Tor i P2P

Istniejące statusy rozdzielają engine, Tor, listener P2P, onion service, relay
i gotowość komunikacji. Aktywny krok pulsuje, sukces jest zielony, warning
pomarańczowy, błąd czerwony, a krok zablokowany szary. Lokalny brak endpointu
P2P blokuje wejście do aplikacji — nie jest traktowany jako kosmetyczne
ostrzeżenie.

Źródłem faktów technicznych pozostaje platforma, a źródłem stanu biznesowego
Rust. Flutter wyłącznie renderuje eventy i odpytuje canonical runtime.

## 4. Android

Właścicielem `AndroidEngineHost`, event pump, Tor i lifecycle jest wyłącznie
`TorChatForegroundService`. `MainActivity` jest adapterem MethodChannel i nie
otwiera drugiej bazy ani drugiej sesji native.

Engine startuje przed Tor, wiąże listener loopback i emituje platform action.
Po pojawieniu się control/SOCKS service wykonuje `ADD_ONION`, zachowuje klucz
onion w `LocalSecretStore` i publikuje `onion_service_available`. Service jest
`START_STICKY`, raportuje sieć, Doze, battery saver i ograniczenie background.
Jawnego force-stop Android nie pozwala aplikacji obejść.

## 5. Desktop

`runtime_engine_stdio` otwiera identity, bazę i engine przed startem Tor.
`TorRuntime` używa trwałego katalogu przekazanego przez CLI, blokady procesu,
trwałych kluczy onion per generation i sterowania `ADD_ONION`. Platform action
jest odkładana do czasu gotowości control portu.

Pełne ramki STDIN/STDOUT nie trafiają już do `desktop.log`; log zawiera tylko
typ komendy/eventu i request ID. Zamknięcie oczekiwane nie emituje błędu
`TorChat runtime stopped unexpectedly`.

## 6. Pairing i tworzenie kontaktu

Pairing przenosi podpisany endpoint w `Welcome` oraz późniejszym
`PeerEndpointBootstrap`. Przed zapisem sprawdzane są identity, fingerprint,
podpis Welcome, zgodność endpointu z nadawcą i canonical contact. Pending
confirmation i acknowledgement są trwałe w migracjach 010–011.

UI rozróżnia obecnie: zaproszenie wygasłe, istniejące zaproszenie/kontakt,
błędny podpis/tożsamość, brak endpointu, endpoint wygasły/stale oraz brak ACK.

## 7. Endpoint registry

`PeerEndpointBundle` sprawdza onion v3, virtual port, identity key, podpis,
wersję, sequence i expiration. Aktualizacja musi być następcą poprzedniego
bundle i nie może zmienić uwierzytelnionej tożsamości. Lokalne i kontaktowe
endpointy są osobnymi rekordami; control-server onion pozostaje konfiguracją
relay, nie rekordem kontaktu.

Serwer relay akceptuje teraz `PeerEndpointBootstrap`, dzięki czemu registry
może zostać uzupełnione po pairingu lub restarcie.

## 8. Direct P2P transport

Wspólny Rust implementuje listener loopback, SOCKS5, WebSocket `/v1/peer`,
challenge-response, wzajemną weryfikację podpisów, limity frame, limity
połączeń, timeouty, endpoint updates i ACK.

Timeout handshake zwiększono do 30 s dla obwodów Tor. Usunięto ukryty
5-sekundowy timeout z odbioru zwykłych frame. Błąd ingress jest emitowany do
engine log bez kluczy, ciphertextu ani MLS state.

Połączenia są obecnie krótkotrwałe per delivery; pełny pool długotrwałych sesji
z okresowym heartbeat pozostaje osobnym etapem optymalizacyjnym. Obsługa
`Ping/Pong` i backoff już istnieje.

## 9. Kolejka wiadomości i ACK

SQLite jest jedyną trwałą kolejką direct/relay. Retry zachowuje `message_id`
i zapisany `wire_ciphertext`; route jest metadanymi próby. Dedup odbiorcy używa
pary `sender_installation_id + message_id`.

Nadawca emituje teraz wszystkie odebrane ACK, w tym `DELIVERED`. `PERSISTED`
pozostaje granicą trwałości i usuwa delivery z retry. Zerwanie socketu już po
`PERSISTED` nie powoduje ponownego dostarczenia tego samego ciphertextu.
Duplikat zapisany jako delivered ponownie otrzymuje poprawny ACK.

## 10. Polityka transportu per kontakt

Canonical enum zawiera `PEER_ONLY`, `PEER_WITH_RELAY_FALLBACK` i `RELAY_ONLY`.
Decyzję podejmuje Rust `ClientEngineActor`; Flutter przesyła tylko wartość
`transportPolicy` w canonical `updateContactSettings`.

Do szczegółów kontaktu dodano selektor polityki. UI nie wybiera route i nie
zmienia stanu wiadomości.

## 11. Relay jako fallback

Router próbuje peer, chyba że polityka to `RELAY_ONLY`; fallback jest dozwolony
wyłącznie dla `PEER_WITH_RELAY_FALLBACK` lub `RELAY_ONLY`. Serwer nie przechowuje
kopert — przesyła je wyłącznie do aktualnie podłączonego odbiorcy.

Walidator relay akceptuje teraz tylko:

- podpisane payloady pairing/control;
- `PeerEndpointBootstrap`;
- poprawnie zakodowany, nieprzezroczysty `PeerCiphertextPayload`.

Limit 128 KiB i walidacja sender/recipient/version pozostają aktywne.

## 12. Kontrakt i migracje

Manifest, wygenerowany Kotlin i wygenerowany Dart zawierają te same nazwy
`getPeerEndpoint`, `updateContactSettings`, statusów endpointu i trzech polityk.
Migracje 007–011 są zarejestrowane w `storage/sqlite.rs`.

Osobna publiczna metoda `setContactTransportPolicy` nie została dodana, ponieważ
repo ma już canonical, generowany `updateContactSettings` z opcjonalnym polem
`transportPolicy`. Dodanie równoległej komendy stworzyłoby drugi kontrakt dla
tej samej operacji.

## 13. Logowanie

`StartupJournal` zapisuje eventy bieżącego uruchomienia, a `scripts/zip.ps1`
zbiera domyślnie ostatni run bez pełnego bugreportu. Skrypt z zachowanych
commitów snapshotu domyślnie dołącza śledzone źródła, a `.git` tylko po
`-IncludeGit`.

Logi transportu zawierają route, retry, ACK i przyczynę błędu. Desktop nie
zapisuje już pełnych komend, odpowiedzi, body wiadomości ani payloadów.
Prywatne klucze, bazy, ciphertext i MLS state pozostają poza paczką.

## Walidacja końcowa

W tym środowisku nie ma toolchainów Cargo, Flutter/Dart ani PowerShell, więc
pełny compile/test musi zostać wykonany na runnerze projektu lub CI:

```text
scripts/torchat.ps1 test --target server
scripts/torchat.ps1 test --target client
scripts/torchat.ps1 test --target android
scripts/torchat.ps1 test --target desktop
scripts/torchat.ps1 contract-check
```

Wykonane lokalnie kontrole niezależne od toolchainu:

- spójność JSON manifestu;
- spójność nazw kontraktu w Rust/Kotlin/Dart;
- brak aktywnych klas legacy wskazanych w punkcie 14;
- `git diff --check`;
- inwentaryzacja i SHA-256 pełnej paczki.
