# TorChat PowerShell CLI

Wszystkie operacje deweloperskie są dostępne przez jeden publiczny entrypoint:

```powershell
.\scripts\torchat.ps1 <command> <target> [options]
```

Logika wykonawcza znajduje się w `scripts/modules/*.psm1`. Pozostałe publiczne pliki `.ps1` są tymczasowymi adapterami zgodnościowymi i delegują do `torchat.ps1`.

## Najczęstsze operacje

```powershell
# Status całego środowiska
.\scripts\torchat.ps1 status all

# Uruchom stack bez usuwania wolumenów i bez rotacji onion
.\scripts\torchat.ps1 stack start

# Inteligentny deploy serwera, Androida i Windowsa
.\scripts\torchat.ps1 deploy all

# Tylko Android
.\scripts\torchat.ps1 deploy android -Device auto

# Tylko Windows
.\scripts\torchat.ps1 deploy windows

# Napraw/restartuj kontener Tor, zachowując klucze onion
.\scripts\torchat.ps1 stack repair

# Zbierz i wyeksportuj diagnostykę
.\scripts\torchat.ps1 logs export
```

Dotychczasowe polecenie nadal działa:

```powershell
.\scripts\redeploy.ps1
```

Jest teraz odpowiednikiem inteligentnego `deploy all` i domyślnie zachowuje onion, bazę serwera oraz dane klientów.

## Drzewo komend

```text
torchat
├── status  all | stack | android | windows
├── stack   start | stop | restart | status | reset | repair
├── build   server | desktop-runtime | android | windows | clients | all
├── deploy  android | windows | all
├── run     android | windows | all
├── stop    android | windows | all
├── clean   build | server-data | client-data | all
├── logs    show | collect | export
└── device  list | pair | connect | status
```

## Polityki

| Parametr | Wartości | Domyślna wartość |
|---|---|---|
| `-BuildPolicy` | `smart`, `rebuild`, `skip` | `smart` |
| `-OnionPolicy` | `preserve`, `rotate` | `preserve` |
| `-DatabasePolicy` | `preserve`, `reset` | `preserve` |
| `-ClientDataPolicy` | `preserve`, `reset` | `preserve` |
| `-StackPolicy` | `ensure`, `skip` | `ensure` |
| `-InstallPolicy` | `if-changed`, `always`, `skip` | `if-changed` |
| `-RunPolicy` | `restart`, `start`, `skip` | `restart` |
| `-Readiness` | `development`, `onion`, `strict` | `development` |
| `-Ui` | `dashboard`, `plain`, `json` | `dashboard` |
| `-Verbosity` | `quiet`, `normal`, `detailed`, `trace` | `normal` |

`run` domyślnie zapewnia lokalny stack przed uruchomieniem klienta. Jeżeli
relay już działa i ma być uruchomiony tylko klient, użyj
`-SkipEnvironmentStart`.

`status` oraz `logs collect/export` są diagnostyczne: awaria Docker Desktop
jest raportowana jako stan częściowy i nie blokuje statusu Windows/Android ani
zbierania dostępnych logów.

`full-deploy -SkipMobileBuild` buduje nadal `desktop-runtime`, ale używa
istniejących artefaktów Flutter Android/Windows. Gdy tych artefaktów nie ma,
wywołanie kończy się jasnym błędem artefaktu.

### Znaczenie readiness

- `development`: lokalny relay i artefakty są wymagane; dłuższy warmup onion kończy deploy ostrzeżeniem.
- `onion`: skrypt dłużej monitoruje onion, ale nadal może zakończyć się ostrzeżeniem.
- `strict`: brak osiągalności onion jest błędem blokującym.

## Reset danych

Zwykły `stack start`, `deploy all` i `redeploy.ps1` nie usuwają wolumenów.

Reset PostgreSQL:

```powershell
.\scripts\torchat.ps1 stack reset -DatabasePolicy reset -Confirm
```

Rotacja onion:

```powershell
.\scripts\torchat.ps1 stack reset -OnionPolicy rotate -Confirm
```

Rotacja onion zmienia adres relaya i wymaga ponownego zbudowania klientów.

## Urządzenia Android

```powershell
.\scripts\torchat.ps1 device list
.\scripts\torchat.ps1 device pair -PairAddress 192.168.1.20:37123 -PairCode 123456
.\scripts\torchat.ps1 device connect -Device 192.168.1.20:43521
.\scripts\torchat.ps1 device status -Device auto
```

## Logi wykonania

Każde uruchomienie zapisuje:

```text
.torchat/runs/<runId>/
├── run.json
├── events.jsonl
├── summary.json
└── logs/
```

Surowe logi Docker, Cargo, Flutter i ADB trafiają do plików. Konsola pokazuje etapy, postęp i podsumowanie.

## Kontrola składni

Przed pierwszym pełnym deployem można uruchomić:

```powershell
.\scripts\tests\Test-TorChatScripts.ps1
```

Test korzysta z parsera PowerShell i nie uruchamia żadnych narzędzi zewnętrznych.
