# TorChat Mobile

Docelowy klient mobilny Flutter dla Androida i iOS.

UI jest wspólnym klientem Flutter dla Androida i desktopu:

- status połączenia onion/Tor,
- zakładki Czaty i Kontakty,
- developerskie kontakty Alice i Bob,
- wyszukiwanie kontaktów,
- ekran rozmowy i composer wiadomości.

Flutter steruje UI przez `lib/mobile_bridge.dart`, a operacje identity/MLS
mogą korzystać bezpośrednio z `lib/torchat_ffi.dart`. Android foreground
service utrzymuje Tor, relay, MLS receive loop i notyfikacje.

Automatyczny build, wykrycie Wi-Fi ADB, start serwera onion, instalacja i
uruchomienie:

```powershell
.\scripts\deploy-android.ps1
.\scripts\deploy-android.ps1 -ResetDevState
```

Skrypt preferuje konkretny endpoint `IP:port`, gdy ADB pokazuje ten sam telefon
również pod nazwą mDNS. `-ResetDevState` czyści lokalną bazę dopiero wewnątrz
nowej, pomyślnie zainstalowanej aplikacji. Nie odinstalowuje starego APK przed
instalacją.

Android może wymagać odblokowania telefonu i potwierdzenia „Install via USB”.
Tej ochrony systemowej skrypt celowo nie omija.

Adres onion pochodzi z runtime environment; profil Alice/Bob i fixture są
wyłącznie opcjonalnym trybem developerskim.
APK podczas buildu. Wi-Fi służy tylko do ADB; API i WebSocket działają przez
lokalny Tor i dokładny adres v3 onion, bez fallbacku LAN.
