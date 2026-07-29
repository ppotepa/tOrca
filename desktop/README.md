# TorChat Desktop

Rust runtime sidecar Windows/Linux. Flutter jest jedynym desktopowym UI;
sidecar używa tego samego `torchat-core`, onion API i relay WebSocket co Android.

Automatyczne uruchomienie całego środowiska developerskiego (Docker, onion i SOCKS Tor):

```powershell
.\scripts\torchat.ps1 run-desktop -Environment local
```

Opcjonalnie własny nick albo przebudowanie obrazów:

```powershell
.\scripts\torchat.ps1 build-clients -Environment local -Target windows -Release
```

Smoke połączenia bez otwierania okna:

```powershell
.\scripts\torchat.ps1 test -Environment local
```

Smoke realnego endpointu pairing (sidecar używa wkompilowanego onionu):

```powershell
$tor = & .\scripts\internal\ensure-desktop-tor.ps1 (Get-Location).Path
.\target\release\torchat-desktop.exe --headless-pairing-code `
  --tor-binary $tor.Binary `
  --tor-data-dir $tor.DataDirectory
```

Wysłanie kodu z drugiego klienta bez UI:

```powershell
.\target\release\torchat-desktop.exe --headless-submit-pairing-code 12345678 `
  --tor-binary $tor.Binary `
  --tor-data-dir $tor.DataDirectory
```

Stack pozostaje uruchomiony po zamknięciu aplikacji. Zatrzymanie wykonuje:

```powershell
.\scripts\torchat.ps1 stop-dev -Environment local
```

W trybie developerskim można załadować fixture rozmowy z Androidem:

```powershell
cargo run -p torchat-desktop -- `
  --server-url http://<v3-onion>.onion `
  --socks5-proxy socks5h://127.0.0.1:9050 `
  --identity-file .\tmp\desktop.key `
  --nickname Desktop `
  --dev-fixture .\protocol\dev-fixtures\android-peer.json `
  --dev-peer <android-installation-id>
```

Desktop nie jest osobnym protokołem: wiadomości są szyfrowane przez MLS lokalnie, a relay przenosi wyłącznie live envelope i receipt. Serwer nie przechowuje wiadomości.
Klient wymaga dokładnego adresu v3 onion i Tor SOCKS; nie posiada trybu LAN.
