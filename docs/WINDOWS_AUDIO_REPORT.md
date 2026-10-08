# Report implementazione audio di sistema Windows

Data: 2026-10-08  
Branch: `agent/pre-home-work`  
Base richiesta: `6bd966e`  
Commit implementazione: `31498e2`

## Risultato

È stata implementata una sorgente reale di audio di sistema Windows basata su
WASAPI loopback. Non è stata usata una simulazione e non sono stati contattati
né aggiornati la lampada o il firmware.

L'app cattura il mix dell'uscita Windows predefinita, lo converte in PCM mono
normalizzato, calcola volume/bassi/medi/alti/battito e trasmette alla cupola
soltanto il livello luminoso risultante. Il PCM non viene scritto su disco e non
viene inviato alla cupola.

## Architettura

- `windows/runner/wasapi_loopback.cpp`: adapter Core Audio nativo. Apre il
  render endpoint predefinito con `AUDCLNT_STREAMFLAGS_LOOPBACK`, converte il
  formato mix e pubblica frame da 1024 campioni.
- `windows/runner/wasapi_loopback.h`: lifecycle isolato del plugin runner.
- MethodChannel `lightdome/windows_audio_commands`: `start` e `stop`.
- EventChannel `lightdome/windows_audio_frames`: mappe con `sampleRateHz` e
  `samples` mono normalizzati.
- `WasapiLoopbackSource`: validazione Dart degli eventi nativi.
- Factory condizionale: Windows usa WASAPI; Web, Android, iOS, Linux e macOS
  usano una sorgente esplicitamente non disponibile.
- `AudioFoundationPanel`: abilita start/stop soltanto su piattaforma supportata
  e con cupola connessa, mostra le bande in tempo reale e aggiorna il tuning
  durante lo stream.
- `AudioStreamCoordinator`: mantiene coalescing e invii non sovrapposti.
- `DeviceController`: collega il coordinator agli endpoint audio firmware e al
  fallback configurato.

## Formati e lifecycle

Sono supportati i mix format Windows float32 e PCM 16/24/32 bit, compreso
`WAVE_FORMAT_EXTENSIBLE`. I canali vengono mediati in mono e limitati a
`[-1, 1]`; le frequenze accettate sono 8–384 kHz.

Start attende fino a cinque secondi la reale inizializzazione WASAPI. Stop è
idempotente, interrompe il thread e rilascia COM e gli oggetti Core Audio. La
perdita dell'endpoint genera un errore di stream, termina la sessione e applica
il fallback. Un nuovo start seleziona nuovamente l'uscita predefinita.

## File modificati o creati

- `lib/controllers/device_controller.dart`
- `lib/core/services/audio_capture_source.dart`
- `lib/core/services/system_audio_source.dart`
- `lib/core/services/system_audio_source_io.dart`
- `lib/core/services/system_audio_source_stub.dart`
- `lib/core/services/wasapi_loopback_source.dart`
- `lib/pages/tabs/audio_foundation_panel.dart`
- `test/audio_feature_processor_test.dart`
- `windows/runner/CMakeLists.txt`
- `windows/runner/flutter_window.cpp`
- `windows/runner/flutter_window.h`
- `windows/runner/wasapi_loopback.cpp`
- `windows/runner/wasapi_loopback.h`
- `README.md`
- `docs/AUDIO_SYSTEM_FOUNDATION.md`
- `docs/WINDOWS_AUDIO_REPORT.md`

Nessun file è stato eliminato, salvo la sostituzione integrale del contenuto
obsoleto di `docs/AUDIO_SYSTEM_FOUNDATION.md`.

## Dipendenze

Nessuna dipendenza Dart, Flutter o di terze parti aggiunta. Il codice nativo usa
soltanto Windows Core Audio, COM, Windows SDK e il channel wrapper Flutter già
presenti nel runner. `ole32.lib` è stato aggiunto al link del runner.

## Endpoint e formati dati

Il protocollo HTTP e il formato `.ldy` non sono cambiati. Sono usati gli
endpoint già presenti:

- `GET /set?y=...&smooth=90&audio=1`
- `POST /audio/config`
- `GET /set?y=0&smooth=350`
- `POST /prog/start?name=...` per il fallback scelto

Sono nuovi soltanto i due channel interni Windows descritti sopra.

## Test e build

- `dart format` sui file Dart modificati: riuscito.
- `flutter analyze --no-pub`: riuscito, nessun problema.
- `flutter test --no-pub`: riuscito, **27 test superati**.
- Test aggiunti: decoding PCM nativo valido e rifiuto di sample rate/campioni
  non validi.
- Compilazione diretta di `wasapi_loopback.cpp` con MSVC 19.44, C++17,
  `/W4 /WX`: riuscita senza warning.
- `flutter build web --release --no-pub --no-tree-shake-icons`: riuscita,
  output `build/web`.
- `flutter build apk --debug --no-pub`: riuscita, output
  `build/app/outputs/flutter-apk/app-debug.apk`.
- `flutter build windows --debug --no-pub`: non eseguibile integralmente su
  questa macchina. Flutter Doctor rileva il Build Tools locale ma lo considera
  privo del workload/component metadata richiesto. Il compilatore MSVC e il
  Windows SDK sono presenti, quindi il nuovo translation unit è stato comunque
  compilato direttamente con gli stessi header Flutter e warning-as-error.
- `git diff --check`: riuscito; restano soltanto avvisi informativi sulla futura
  conversione CRLF di file Windows.

Non è stato eseguito uno smoke test che acquisisce audio reale: avrebbe aperto
la cattura del mix dell'utente senza una sessione interattiva e senza poter
verificare in modo trasparente ciò che era in riproduzione.

## Limiti e rischi

- La build Windows completa deve essere ripetuta su un ambiente Flutter con il
  workload Visual Studio "Desktop development with C++" riconosciuto.
- L'adapter usa l'uscita predefinita; non è ancora presente un selettore manuale
  degli endpoint.
- Un cambio dell'uscita predefinita durante lo stream può terminare la sessione;
  il fallback interviene e un riavvio aggancia il nuovo endpoint.
- Latenza LAN, comportamento del watchdog e resa luminosa richiedono la prova
  fisica.
- WASAPI loopback può essere bloccato per contenuti protetti da DRM, per regole
  del sistema operativo.

## Prova manuale richiesta

1. Installare/verificare il workload Visual Studio C++ e costruire l'app Windows.
2. Collegare la cupola e scegliere dissolvenza come fallback.
3. Avviare audio Windows durante silenzio e verificare valori prossimi a zero.
4. Riprodurre un tono o musica nota e verificare movimento dei cinque indicatori.
5. Modificare sensibilità, soglia, attack, release e pesi durante lo stream.
6. Fermare normalmente e verificare la dissolvenza.
7. Ripetere con un pattern locale come fallback.
8. Cambiare/scollegare l'uscita audio e verificare errore leggibile e fallback.
9. Lasciare attivo almeno dieci minuti e controllare latenza, CPU e stabilità Wi-Fi.
10. Confermare che Web/Android non mostrino il pulsante come disponibile.

## Rollback e riparazione

- Rollback completo: `git revert 31498e2` e revert del successivo commit docs.
- Per disabilitare soltanto la funzione mantenendo il codice, fare restituire
  `UnavailableSystemAudioSource` dalla factory Windows.
- Se il runner non compila, verificare prima il workload Visual Studio C++ e il
  Windows SDK; non rimuovere il watchdog firmware come workaround.

## Stato finale

La funzione è implementata e verificata staticamente/unitariamente. Non viene
dichiarata collaudata end-to-end finché non saranno completate la build Windows
integrale e la prova manuale con audio e cupola reali.
