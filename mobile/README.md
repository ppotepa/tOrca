# TorChat Mobile

Docelowy klient mobilny Flutter dla Androida i iOS.

UI jest wspólnym klientem Flutter dla Androida i desktopu:

- status połączenia onion/Tor,
- zakładki Czaty i Kontakty,
- lokalne kontakty i rozmowy zapisane w urządzeniu,
- wyszukiwanie kontaktów,
- ekran rozmowy i composer wiadomości.

Flutter steruje UI przez `lib/mobile_bridge.dart`, a z operacji identity/MLS
korzysta Android foreground service i wspólny Rust core; Flutter nie
wywołuje już bezpośrednio warstwy Dart FFI. Android foreground
service utrzymuje Tor, relay, MLS receive loop i notyfikacje.

Automatyczny build, wykrycie Wi-Fi ADB, start serwera onion, instalacja i
uruchomienie:

```powershell
.\scripts\torchat.ps1 deploy-mobile -Environment local
.\scripts\torchat.ps1 deploy-mobile -Environment local -Clean
```

Skrypt preferuje konkretny endpoint `IP:port`, gdy ADB pokazuje ten sam telefon
również pod nazwą mDNS. `-Clean` czyści lokalny stan klienta podczas
kontrolowanego deployu.

Android może wymagać odblokowania telefonu i potwierdzenia „Install via USB”.
Tej ochrony systemowej skrypt celowo nie omija.

Adres onion pochodzi z runtime environment podczas buildu i jest wbudowany w
APK; profil Alice/Bob i fixture są
wyłącznie opcjonalnym trybem developerskim i nie należą do normalnego flow.
APK podczas buildu. Wi-Fi służy tylko do ADB; API i WebSocket działają przez
lokalny Tor i dokładny adres v3 onion, bez fallbacku LAN.
