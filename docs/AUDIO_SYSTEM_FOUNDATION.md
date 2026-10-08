# Audio della riproduzione Android

La modalità attiva è limitata all'app Android 10 o successiva. Web, iOS e
desktop non mostrano controlli di avvio e non tentano di acquisire audio.

## Flusso

1. L'utente collega l'app alla cupola e tocca **Avvia audio del telefono**.
2. Android verifica `RECORD_AUDIO` e mostra il consenso MediaProjection. Il
   consenso viene richiesto di nuovo a ogni sessione e il token non è riusato.
3. Un foreground service acquisisce soltanto la riproduzione consentita dalle
   app sorgente tramite `AudioPlaybackCapture`.
4. PCM16 mono transitorio viene validato e normalizzato in Dart. Non viene
   scritto su file, preferenze o log.
5. `AudioFeatureProcessor` ricava volume, bassi, medi, alti e battito. Gain,
   gate, attack, release e pesi producono l'intensità inviata alla cupola.
6. `AudioStreamCoordinator` conserva solo l'ultimo livello in attesa e non
   sovrappone richieste HTTP.

## Limiti dichiarati

- Le app possono vietare la cattura; DRM e contenuti protetti possono produrre
  silenzio anche dopo il consenso.
- Android 9 e versioni precedenti non sono supportati.
- La cattura termina quando l'utente la ferma, revoca MediaProjection o rimuove
  l'app dalle attività recenti.
- Se il flusso si interrompe, il watchdog della cupola applica la dissolvenza o
  avvia il pattern locale di riserva configurato.
- Un microfono fisico nella lampada resta una possibile evoluzione futura; non
  è simulato dall'app attuale.

Il collaudo su telefono e lampada reali è ancora obbligatorio: una build
riuscita non dimostra che una specifica app musicale autorizzi la cattura.
