# Audio del computer

## Stato

L'app desktop Windows dispone di una sorgente reale WASAPI loopback. Acquisisce
il mix riprodotto dall'uscita audio predefinita di Windows, lo converte in PCM
mono normalizzato e lo passa al processore Dart già condiviso.

Android, iOS e Web non dichiarano supporto per l'audio di sistema. Il browser,
in particolare, non viene presentato come supportato: la pagina embedded è
servita via HTTP locale e non può garantire una cattura schermo/audio sicura e
portabile. Il microfono resta una funzione separata.

## Flusso

1. `WasapiLoopbackPlugin` apre l'endpoint render predefinito (`eConsole`) in
   modalità condivisa con `AUDCLNT_STREAMFLAGS_LOOPBACK`.
2. Il thread nativo accetta i formati mix float32 e PCM 16/24/32 bit, riduce i
   canali a mono e produce frame da 1024 campioni in `[-1, 1]`.
3. `WasapiLoopbackSource` valida frequenza e campioni ricevuti dal channel.
4. `AudioFeatureProcessor` ricava volume, bassi, medi, alti e battito e applica
   gain, gate, attack, release, minimo, massimo e pesi configurati nella UI.
5. `AudioStreamCoordinator` conserva soltanto il livello più recente e non
   sovrappone richieste HTTP.
6. Il firmware riceve `/set?...&audio=1`; in caso di perdita della sorgente usa
   il watchdog e il fallback configurato.

Il PCM resta nel processo locale. Alla cupola viene inviato soltanto il livello
luminoso derivato, non l'audio.

## Avvio e arresto

- Il pulsante è disponibile soltanto nell'app Windows e con cupola connessa.
- Start e stop sono idempotenti; il thread e le interfacce COM vengono chiusi
  anche quando la pagina viene abbandonata.
- Se l'endpoint scompare o WASAPI restituisce un errore, lo stream termina e
  viene applicato il fallback: dissolvenza oppure pattern locale.
- Se cambia l'uscita predefinita durante la cattura, fermare e riavviare la
  modalità per agganciare il nuovo endpoint.

## Compatibilità e fonti

Non sono state aggiunte dipendenze. L'adapter usa le API Windows Core Audio già
incluse nel Windows SDK. WASAPI loopback richiede un endpoint render e modalità
shared, come documentato da Microsoft:

- https://learn.microsoft.com/windows/win32/coreaudio/loopback-recording
- https://learn.microsoft.com/windows/win32/coreaudio/audclnt-streamflags-xxx-constants

## Verifiche ancora manuali

- eseguire l'app Windows costruita con il workload Visual Studio C++ completo;
- provare silenzio, parlato, musica e toni bassi/alti;
- cambiare uscita Windows durante lo stream e verificare il recupero;
- verificare latenza e stabilità sulla rete reale della cupola;
- verificare dissolvenza e pattern di riserva scollegando intenzionalmente la
  sorgente.
