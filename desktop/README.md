# TorChat Desktop

Rust runtime sidecar Windows/Linux. Flutter jest jedynym desktopowym UI;
sidecar używa tego samego `torchat-core`, onion API i relay WebSocket co Android.

Automatyczne uruchomienie całego środowiska developerskiego (Docker, onion i SOCKS Tor):

```powershell
.\scripts\torchat.ps1 run -Environment local -Target windows
```

Opcjonalnie własny nick albo przebudowanie obrazów:

```powershell
.\scripts\torchat.ps1 build -Environment local -Target windows -Release
```

Smoke połączenia bez otwierania okna:

```powershell
.\scripts\torchat.ps1 test -Environment local
```

Stack pozostaje uruchomiony po zamknięciu aplikacji. Zatrzymanie wykonuje:

```powershell
.\scripts\stop-dev.ps1
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
