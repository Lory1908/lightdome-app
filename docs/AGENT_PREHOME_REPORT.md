# LightDome — rapporto agente software senza lampada
Data: 2026-10-08 | Repository: https://github.com/Lory1908/lightdome-app

## 1. Punto di partenza e regole
- Repository locale: `J:\repos\active\lightdome-app`.
- Branch originale: `chore/firmware-platformio-bootstrap`, commit esatto `9028953bd28d7e6093c51d3e9e8a5eaf9028db06`.
- Stato iniziale: working tree pulito, nessun cambiamento altrui presente.
- Letti prima delle modifiche: `J:\AGENTS.md`, `J:\agents\WORKFLOW.md`, `J:\agents\README.md`, `CURRENT_STATE.md`, `REPO_ROUTING.md`. Nessun `AGENTS.md` nella root del repository o negli antenati vicini rilevati.
- Non è stato tentato alcun accesso alla lampada, flash, OTA, controllo del dispositivo, chiamata a `lightdome.local` o al suo IP. Nessun force push, merge o PR.

## 2. Branch di lavoro
`agent/pre-home-work`, creato con `git switch -c agent/pre-home-work` dal commit originale. Il branch iniziale resta invariato.

## 3. Implementazioni completate
### Priorità 1 — Editor Flutter
- Nuova azione **Modifica** sui pattern salvati: `/prog/meta` recupera i metadati.
- Conversione fra ricette WebUI (`preset: breath/pulse/sunrise/random`, percentuali, `easing: sine`) e modello Flutter (`organic`, `natural`); ricostruzione durata, min/max, duty, easing, irregolarità, loop, autorun.
- Nuovi LDY scritti con metadati JSON in coda ai campioni; l'header LDY1 resta a 12 byte e i file legacy con lunghezza metadati 0 restano validi. Campionamento a 250 Hz senza selettore UI.
- L'editor preesistente viene riaperto su schermata dedicata con nome originale bloccato. Il firmware esegue validazione e sostituzione atomica del file caricato. Errori non-404 non vengono interpretati come assenza di metadata.
- Su LDY legacy privi di metadati l'app **non ricostruisce la vera curva**: mostra valori prudenti *stimati* e un messaggio esplicito prima della sostituzione.

### Priorità 2 — Audio di sistema (fondamenta)
- Interfaccia di sorgente audio PCM mono; elaborazione offline di volume RMS, bassi, medi, alti, beat, sensibilità, gate, attack/release e livelli minimo/massimo.
- Pannello Flutter con parametri, provenienza e stato. La sorgente audio di sistema è chiaramente **non disponibile**, con comando di avvio disabilitato; il microfono esistente resta separato.
- Test unitari con sorgente fittizia, senza dispositivi reali. Nessuna libreria di cattura aggiunta; un adapter Windows WASAPI loopback resta da realizzare.

### Priorità 3 — Sicurezza della perdita audio
- Firmware: watchdog *opt-in* soltanto per `GET /set?y=...&audio=1`; scadenza dopo 1200 ms dall'ultimo frame.
- Alla scadenza: dissolvenza a zero in 350 ms oppure avvio di un pattern locale selezionato in precedenza.
- `POST /audio/config` imposta il fallback in RAM. Flutter contiene il wrapper HTTP, un selettore di comportamento, e `AudioStreamCoordinator` con callback di perdita sorgente. Il normale flusso audio reale **non è collegato** perché manca la cattura di sistema.
- Firmware compilato; non installato né verificato sulla lampada.

### Priorità 4 — Pacchetto di authoring LLM
- Schema JSON dichiarativo, prompt, quattro esempi (respiro/battito/alba/organico), validatore Python standard library, compiler LDY1 250 Hz e preview ASCII obbligatoria prima della scrittura.
- Conversione solo offline; nessun upload automatico, nessuna esecuzione di codice generato, limiti/chiavi controllati, output esistente mai sovrascritto.

### Priorità 5 — Web/iPhone
- Manifest PWA identificato come LightDome, colori coerenti, icone normal/maskable, icona Apple da 180 px, favicon rigenerato e meta tag Safari.
- Messaggi semplici su connessione IP/`lightdome.local`, stessa rete LAN, offline e assenza cloud. Test widget su 320/390 px e temi chiaro/scuro.
- Documentati HTTPS, origine browser, mixed content e limiti reali di installazione e connettività iPhone. Nessuna affermazione di collaudo iPhone.

## 4. Incompleto e volutamente rinviato
- Cattura audio Windows via WASAPI loopback, permessi/cattura audio browser, streaming reale ed elaborazione di feature sul dispositivo finale.
- Prove su lampada del watchdog e del fallback, della qualità PWM a bassa luminosità, del sample rate e del playback autonomo.
- Esperienza Safari iPhone reale (installazione Home, connessione, permessi LAN, background), OTA/autenticazione/ripristino dopo aggiornamento.
- Il provider Windows dovrà avere un adattatore compatibile con `AudioCaptureSource`; il controller avvierà il flusso usando `DeviceApi.sendAudioY`, configurerà il fallback e invierà `stopAudio` allo stop regolare.
- Il formato attuale veicola l'intensità derivata dalle bande, non uno stream di cinque feature verso l'ESP; non viene dichiarato il contrario.

## 5. Elenco completo file del lavoro
M = modificato, A = aggiunto. Nessun file tracked eliminato. Si include questo rapporto (A).

```text
M README.md
A docs/AGENT_PREHOME_REPORT.md
A docs/AUDIO_SYSTEM_FOUNDATION.md
A docs/AUDIO_WATCHDOG.md
A docs/WEB_IPHONE.md
A docs/llm-pattern-authoring/PROMPT.md
A docs/llm-pattern-authoring/README.md
A docs/llm-pattern-authoring/examples/breath.json
A docs/llm-pattern-authoring/examples/organic.json
A docs/llm-pattern-authoring/examples/pulse.json
A docs/llm-pattern-authoring/examples/sunrise.json
A docs/llm-pattern-authoring/ldy_recipe.py
A docs/llm-pattern-authoring/recipe.schema.json
A docs/llm-pattern-authoring/tests/test_ldy_recipe.py
M firmware/README.md
M firmware/src/main.cpp
M lib/controllers/device_controller.dart
M lib/core/api/device_api.dart
M lib/core/ldy/ldy_encoder.dart
A lib/core/models/pattern_draft.dart
A lib/core/services/audio_capture_source.dart
A lib/core/services/audio_feature_processor.dart
A lib/core/services/audio_stream_coordinator.dart
A lib/pages/tabs/audio_foundation_panel.dart
M lib/pages/tabs/create_page.dart
M lib/pages/tabs/programs_page.dart
M lib/pages/tabs/settings_page.dart
A test/audio_feature_processor_test.dart
A test/audio_stream_coordinator_test.dart
A test/mobile_theme_smoke_test.dart
A test/pattern_draft_test.dart
A tools/generate_icons.py
M web/favicon.png
M web/icons/Icon-192.png
M web/icons/Icon-512.png
M web/icons/Icon-maskable-192.png
M web/icons/Icon-maskable-512.png
A web/icons/apple-touch-icon.png
M web/index.html
M web/manifest.json
```

## 6. Dipendenze
- Nessuna modifica a `pubspec.yaml`, `pubspec.lock`, `platformio.ini` o versioni di librerie firmware.
- Python 3.12 (standard library) usato per il kit LLM. Pillow 12.2.0, **già disponibile sul PC**, usato unicamente dallo script `tools/generate_icons.py` per rigenerare i PNG; non è una dipendenza di runtime Flutter o ESP8266.

## 7. Contratti/API/formati
- **Nuovo (retrocompatibile):** `GET /set?y=...&audio=1`: arma/aggiorna il timeout. `GET /set?y=...` senza flag mantiene il vecchio comportamento.
- **Nuovo:** `POST /audio/config` con `{"fallback": null}` oppure `{"fallback":"nome"}` esistente e validato. Nessuna persistenza in flash; `/api/state` aggiunge `audioStreamActive` e `audioFallback`.
- **Già presente, ora usato da Flutter:** `GET /prog/meta?name=...` per JSON ricetta; 404 per file legacy senza metadati.
- **Formato LDY1 invariato:** magic `LDY1`, uint16 LE sample rate, uint32 LE frame count, uint16 LE lunghezza metadata, payload `frameCount * uint16 LE` 0..1023, JSON UTF-8 opzionale in coda (max 2048 byte). I nuovi pattern utilizzano 250 Hz. File senza metadati preservati.
- Il parser dell'elenco Flutter ora elimina il prefisso `/prog/` e file non `.ldy`/temporanei. In fase di modifica il nome originale è mantenuto e il firmware salva atomicamente.

## 8. Compatibilità e rischi
- Client firmware legacy non marcano `audio=1` e non subiscono nuovi spegnimenti automatici.
- Un guasto Wi-Fi può causare un timeout e il fallback anche con audio ancora attivo: comportamento prudenziale previsto.
- `/audio/config` disponibile solo con **nuovo firmware compilato ma non installato**; la UI ne segnala il possibile errore.
- Nome e metadati LDY legacy possono soltanto essere **stimati**, non recuperati con fedeltà. Prima della sostituzione fare un backup reale quando la lampada è disponibile.
- L'host `lightdome.local` e l'accesso HTTP dalla Web Flutter dipendono da mDNS, origine e permessi browser. Non è stata implementata una PWA offline con controllo garantito su Safari iOS.
- Nessun cloud, segreto o dipendenza di controllo Internet introdotti. L'HTTP LAN resta senza autenticazione (precedente condizione del sistema, non estesa a Internet).

## 9. Verifiche e risultati esatti
Eseguiti da `J:\repos\active\lightdome-app` su Windows:
- `dart format` sui Dart nuovi/modificati: **exit 0**.
- `flutter test --no-pub --reporter compact`: **exit 0, 23 test superati**, nessun failure.
- `flutter analyze --no-pub`: **exit 0, No issues found**.
- `python -m unittest discover -s docs/llm-pattern-authoring/tests -v`: **exit 0, Ran 4 tests, OK**.
- `flutter build web --release --no-tree-shake-icons --no-pub`: **exit 0, Built build\\web**.
- `flutter build apk --debug --no-pub`: **exit 0, Built build\\app\\outputs\\flutter-apk\\app-debug.apk**.
- `pio run -d firmware -e nodemcuv2` con eseguibile `C:\Users\loryc\.platformio\penv\Scripts\pio.exe`: **exit 0, SUCCESS**, RAM 68.7%, flash 41.2%.
- `git diff --check 9028953 HEAD`: **exit 0**, nessun whitespace error.
- `git status --porcelain=v1 -b` prima del rapporto: **solo branch, nessuna modifica**.
Non sono stati eseguiti flash, prove della lampada né cattura audio Windows reale.

### Errori incontrati e corretti
1. `flutter analyze` iniziale: due lints P1 relativi a parentesi; corretti, analisi successiva pulita.
2. `flutter analyze` P3: tre lints relativi a parentesi/nome parametri; corretti, analisi successiva pulita.
3. Test Python iniziale fallito su terminale Windows `charmap` a causa di caratteri Unicode nella preview; corretta con preview ASCII; test rilanciati e superati.
4. Primo tentativo di esecuzione build Web ha restituito un errore interno del connettore; rilanciato e completato regolarmente con exit 0.

### Warning non bloccanti
- PlatformIO/framework ESP8266: due `SyntaxWarning: invalid escape sequence '\\s'` in `elf2bin.py`, non nel codice progetto.
- Flutter Web: avviso informativo Wasm dry run; build release riuscita.
- `flutter pub get` segnalava 53 pacchetti con versioni più nuove incompatibili coi vincoli attuali; nessun upgrade tentato.

## 10. Build prodotte
- Web release: `J:\repos\active\lightdome-app\build\web\`.
- APK debug: `J:\repos\active\lightdome-app\build\app\outputs\flutter-apk\app-debug.apk` (168993684 byte).
- Firmware compilato, **non flashato**: `J:\repos\active\lightdome-app\firmware\.pio\build\nodemcuv2\firmware.bin` (434128 byte).
- Artefatti build ignorati da Git e non pubblicati nel branch. La vecchia build consegnata al commit `9028953` resta distinta in `J:\data\lightdome\builds\2026-10-08`.

## 11. Commit creati in ordine
1. `c98006d` — `feat(flutter): edit stored patterns with compatible LDY metadata`
2. `4f51d8d` — `feat(audio): scaffold honest system-audio analysis and UI`
3. `0f83037` — `feat(firmware): opt-in audio watchdog with safe local fallback`
4. `e795390` — `feat(patterns): add offline validated LLM authoring kit`
5. `18978c8` — `feat(web): polish mobile onboarding and PWA assets`
6. `docs: record pre-home implementation, verification and recovery report` — commit contenente questo rapporto, identificabile come l'ultimo `git log` del branch.

## 12. Riparazione e annullamento
**Per abbandonare tutte le modifiche senza toccare il branch originale**:
```powershell
cd J:\repos\active\lightdome-app
git switch chore/firmware-platformio-bootstrap
# Solo se si desidera esplicitamente eliminare il branch di lavoro, dopo averne verificato il contenuto:
git branch -D agent/pre-home-work
# La cancellazione del branch remoto è separata e va fatta SOLO su richiesta:
# git push origin --delete agent/pre-home-work
```
Questo non ripristina file di build ignorati; sono outputs locali rigenerabili, non modifiche a sorgenti. Non eseguire `git reset --hard` o `git clean -fd` su cambiamenti propri o di altri.

**Per annullare selettivamente** in un nuovo branch: prima verificare `git status` pulito, poi usare `git revert <commit>` in ordine inverso (report, `18978c8`, `e795390`, `0f83037`, `4f51d8d`, `c98006d`), gestendo eventuali conflitti; nessun force push necessario. Rieseguire tutti i test e le build. In caso di errore durante un revert, leggere `git status` e scegliere consapevolmente `git revert --abort` (solo per il revert in corso).

**Riparazioni mirate**:
- Editor/LDY: riprodurre i test `pattern_draft_test.dart`, controllare i 12 byte dell'header e l'eventuale metadata; eventuale rollback P1 via revert `c98006d`.
- Audio: disabilitare l'avvio reale finché non esiste provider; revert P2 `4f51d8d`. Per recupero firmware revert P3 `0f83037` (oppure firmware originale dopo un futuro flash, solo con accesso fisico).
- Kit LLM: revert `e795390` rimuove schema, convertitore ed esempi. Se output è rifiutato, correggere JSON e rieseguire `validate`, senza `eval`.
- iPhone/icona: revert `18978c8` riporta manifest, immagini e copy precedenti. Rigenerare PNG offline con `python tools/generate_icons.py` se i file differiscono.
- Nessun dispositivo è stato aggiornato in questo lavoro: nulla da ripristinare sulla lampada.

## 13. Checklist per quando il proprietario torna a casa
- [ ] Collegare la lampada e **solo allora** flashare consapevolmente il firmware compilato, con porta seriale verificata.
- [ ] Confrontare gli stessi pattern a **150, 250, 300 Hz**, mantenere 250 se non esiste vantaggio visivo senza regressioni.
- [ ] Verificare manualmente luminosità **1%, 3%, 5%, 10%, 15%, 20%** e transizioni brevi.
- [ ] Eseguire un pattern **250 Hz per almeno 5 minuti** con app e sito completamente chiusi.
- [ ] Dall'app: crea, salva, modifica, sostituisci ed elimina; confermare persistenza e risposta su Wi-Fi.
- [ ] Provare recupero parametri di file con metadati e comportamento esplicito di vecchi LDY senza ricetta.
- [ ] Simulare perdita di invio audio marcato: confermare fade 350 ms, scelta fallback, assenza di luce bloccata, funzionamento dei comandi legacy.
- [ ] Dopo adapter WASAPI reale: verificare permessi, latenza, volume/bassi/medi/alti/battito, stop e crash di app/processo.
- [ ] Su iPhone reale: Safari, Add to Home Screen, tema, mDNS/IP manuale, accesso LAN, limiti HTTPS/mixed-content, offline, riapertura.
- [ ] Valutare separatamente OTA autenticato, backup, recovery e procedura di rollback, senza eseguire installazioni improvvisate.

## 14. Conclusione
Le cinque priorità software sono state sviluppate nella misura verificabile **senza lampada**. Audio di sistema e controllo iPhone reale restano intenzionalmente non dichiarati pronti. Il progetto deve essere riesaminato con i checkpoint fisici prima di rilasciare una versione per l'uso reale.
