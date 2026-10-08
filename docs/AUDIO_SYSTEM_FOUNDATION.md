# Audio del computer (fase preparatoria)

- **Nessuna cattura di audio di sistema è oggi abilitata**: la UI mostra chiaramente 'Non attiva'.
- `AudioCaptureSource` espone PCM mono normalizzato e sample rate. `AudioFeatureProcessor` produce RMS/volume, bassi, medi, alti, beat e intensità filtrata con gate, gain, attack/release e limiti minimo/massimo.
- I test usano `SimulatedPcmSource` per generare campioni deterministici. Non esiste alcuna cattura simulata presentata come reale nell'app.
- Windows: implementare un adapter WASAPI **loopback** nativo con consenso e scelta del dispositivo di output. Valutare FFI tramite i componenti Windows/Core Audio documentati o un plugin desktop supportato e mantenuto; non aggiungere ora una libreria non verificata.
- Browser: `getDisplayMedia` con richiesta esplicita dell'utente e traccia audio disponibile **solo** nei contesti supportati e sicuri (HTTPS o localhost). L'API non garantisce la cattura dell'audio di sistema; i permessi e la selezione sono responsabilità del browser. Non inserire una finta modalità sempre attiva.
- La pagina embedded servita dall'ESP8266 su HTTP LAN non è un contesto sicuro per garantire `getDisplayMedia`. Non implementare cattura lì.
- Il microfono rimane la modalità separata già esistente, non viene usato come sostituto automatico.
- Il trasporto futuro invierà **feature** (volume, bass, mid, treble, beat) o intensità; l'adapter deve applicare il watchdog firmware in caso di stop/crash. Per ora non viene avviato alcuno streaming audio di sistema.
- Il processamento delle bande usa una banca di filtri Goertzel per frame PCM brevi. Servono prove su rumore, frequenze, latenze, normalizzazione e consumo CPU prima della distribuzione.
