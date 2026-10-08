# LightDome – App Flutter per Cupola Luminosa

Client Flutter per controllare, via rete locale (LAN), il firmware della cupola luminosa su ESP8266/ESP32. Nessun cloud, bassa latenza, UI a tab per controllo LIVE, programmi e impostazioni.

Per una panoramica completa di architettura, moduli, API e scelte progettuali vedi:

- Documentazione estesa: `docs/PROJECT_OVERVIEW.md`

## Requisiti

- Flutter SDK installato
- Dispositivo della cupola raggiungibile in LAN (IP o mDNS)
 - Su Windows: attiva la "Modalità Sviluppatore" (necessaria ai plugin)
   - Esegui: `start ms-settings:developers` e abilita l'opzione

## Esecuzione rapida

- Android: `flutter run -d android`
- Web (Edge/Chrome): `flutter run -d edge` oppure `flutter run -d chrome`

## Onboarding

1. Alla prima accensione collegati dal telefono o PC alla rete
   `LightDome-Setup`.
2. Nell’app apri `Impostazioni` → `Configura il Wi-Fi della cupola`, cerca la
   rete di casa, inserisci la password e premi `Salva e collega`.
3. In alternativa, da PC apri `http://192.168.4.1`: il portale offre la stessa
   configurazione senza richiedere l’app.
4. Dopo il riavvio ricollegati al Wi-Fi di casa e usa
   `http://lightdome.local` oppure l’indirizzo IP assegnato dal router.

Le credenziali non sono presenti nel sorgente, non vengono salvate nell’app e
non vengono restituite dalle API. Restano soltanto nella memoria locale della
scheda.

## Funzioni principali

- Dashboard: stato in tempo reale, `Aggiorna`, `Spegni`.
- Live: slider intensità (coalescing ~60 Hz), brightness%, gamma, loop, preset rapidi OFF/25/50/75/100.
- Programmi: elenco, Play/Stop/Delete su file `.ldy` presenti nel device.
- Pattern locali: `Sine`, `Pulse` e `Mic reattivo` (senza account, stream in tempo reale).
- Anteprima: pagina dedicata che mostra un alone radiale in tempo reale (segue il segnale TX, anche offline).
- Impostazioni: configurazione Wi-Fi della scheda e gestione connessione
  (IP/mDNS).

## Novità

- Salvataggio automatico dell’ultimo dispositivo: l’IP/mDNS inserito viene memorizzato e ripristinato al successivo avvio.
- UI più pulita: tema Material 3 rivisto, card per sezioni, spaziature e controlli migliorati su tutte le pagine.
- Modalità Mic reattivo: usa il microfono del dispositivo per reagire al suono in tempo reale (streaming verso la cupola).
- Provider esterni (Spotify / open): disabilitati di default e selezionabili in futuro. L'integrazione Spotify non viene più compilata di default: i pacchetti `spotify_sdk` e `spotify` sono stati rimossi dal `pubspec` per evitare dipendenze native aggiuntive.
- Selettore modalità a tendina (Nessuna/Sine/Pulse/Mic) con parametri visualizzati solo quando pertinenti.
- Compensazione gamma opzionale per Sine/Pulse/Mic, frequenza estesa (0.05–20 Hz) e Duty per Pulse.
- Toggle da Impostazioni: “Mostra anteprima cupola” e “Mostra descrizioni controlli”.

## Compatibilità Firmware

- Stato: `/api/state` (preferito) con fallback `/status`.
- LIVE: `/set?y=` (0..1023), `/params?brightness=0..100&gamma=1.0..3.0&loop=0|1`.
- Programmi: `/prog/list`, `/prog/start`, `/prog/stop`, `/prog/delete`.
- Configurazione rete: `/wifi/status`, `/wifi/scan`, `/wifi/config`. Scansione
  e salvataggio sono accettati solo da un client collegato all’AP di setup.

## Controllo e collaudo da PC

Il firmware espone direttamente API HTTP e una WebUI tecnica. Se non riesce a
collegarsi alla rete configurata, apre l’AP `LightDome-Setup`: collegare il PC a
quella rete e aprire `http://192.168.4.1`. Il portale captive dovrebbe anche
aprirsi automaticamente. Una volta collegato alla LAN, la WebUI tecnica è
disponibile su `http://lightdome.local`.

Per controllo e test da PowerShell, senza installare dipendenze:

```powershell
# Test non distruttivo di stato, filesystem e connettività
.\tools\lightdome.ps1 smoke

# Livello LIVE 0..1023
.\tools\lightdome.ps1 set -Level 256

# Master brightness, gamma e loop
.\tools\lightdome.ps1 params -BrightnessPct 80 -Gamma 2.2 -Loop on

# Gestione programmi
.\tools\lightdome.ps1 programs
.\tools\lightdome.ps1 start -Name demo
.\tools\lightdome.ps1 stop
.\tools\lightdome.ps1 upload -Name demo -File .\demo.ldy
```

Per un dispositivo già collegato alla LAN usare `-BaseUrl`, per esempio
`-BaseUrl http://lightdome.local`. Il comando `smoke` esegue soltanto letture;
gli altri comandi modificano esplicitamente lo stato indicato.

## Feature flag

- File: `lib/core/config/app_features.dart`
  - `enableSpotify`: abilita/disabilita l'integrazione con Spotify. Per riattivarla servono dipendenze e credenziali opzionali, vedi sezione "Provider esterni".
  - `enableOpenProvider`: abilita la card "Open provider (file locale)" per creare `.ldy` da un file audio.
  
## Impostazioni UI (persistenti)

- File: `lib/core/services/app_settings.dart`
  - `showPreview`: mostra/nasconde la tab Anteprima.
  - `showDescriptions`: mostra/nasconde le descrizioni sotto agli slider.

## Permessi

- Microfono: richiesto solo per la modalità `Mic reattivo` (Android/iOS). Concedere alla richiesta.
- Windows Desktop: è necessaria la Modalità Sviluppatore per il corretto funzionamento dei plugin.

## Roadmap rapida

- Persistenza device + discovery mDNS
- Provider aperto senza account (cataloghi pubblici) e/o Spotify opzionale

## Provider esterni (Spotify/Open)

L'applicazione include ancora i flag e il codice sorgente per integrazioni Spotify e "open provider", ma i pacchetti non sono più installati di default per semplificare la build mobile.

Per riattivare Spotify:

1. Aggiungi al `pubspec.yaml` le dipendenze commentate:
   ```yaml
   dependencies:
     spotify_sdk: ^3.0.2
     spotify: ^0.13.6
   ```
2. Configura le chiavi OAuth seguendo la documentazione del provider.
3. Imposta `AppFeatures.enableSpotify = true` e ricompila.

L'open provider richiede allo stesso modo di abilitare `AppFeatures.enableOpenProvider` e assicurarsi delle autorizzazioni per l'accesso ai file locali.

## Build rapide

- Debug APK locale (firmato con keystore debug standard):
  ```bash
  flutter pub get
  flutter build apk --debug
  ```
- Installazione su dispositivo collegato:
  ```bash
  flutter install
  ```
Per una build release destinata alla distribuzione occorre configurare un keystore dedicato (vedi documentazione Android standard).
- Upload `.ldy` con progress
- OTA e reconnect automatico
- WebSocket opzionale per ridurre polling

## Preparazione software senza lampada (ottobre 2026)

- Flutter supporta la modifica delle ricette salvate tramite `/prog/meta`,
  con fallback esplicito per i file LDY legacy senza metadati.
- L’app Android 10+ può acquisire, dopo consenso esplicito, l’audio riprodotto
  dalle app che lo permettono. Web, iOS e desktop restano non supportati. Vedi
  `docs/AUDIO_SYSTEM_FOUNDATION.md` e `docs/ANDROID_AUDIO_REPORT.md`.
- Il watchdog firmware audio è opzionale e ancora da collaudare fisicamente.
  Vedi `docs/AUDIO_WATCHDOG.md`.
- Schema, esempi e conversione sicura locale per ricette generate da LLM:
  `docs/llm-pattern-authoring/README.md`.
- Manifest, icone e limiti iPhone/browser: `docs/WEB_IPHONE.md`.
- I collaudi fisici restano in `docs/PATTERN_SYSTEM.md`.
