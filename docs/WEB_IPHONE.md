# LightDome su iPhone e browser — limitazioni e preparazione

## Cosa funziona senza cloud

L'app Flutter Web usa HTTP per parlare direttamente con la cupola nella **stessa rete locale**. Nelle Impostazioni si può inserire `lightdome.local` oppure l'IP visualizzato dal router; su browser la ricerca mDNS automatica non è disponibile. Se l'indirizzo non risponde, controllare prima Wi-Fi, alimentazione e IP. La navigazione Flutter è responsive e offre tema chiaro/scuro.

Il manifest `web/manifest.json`, le nuove icone `web/icons` e i meta tag Apple rendono la build più adatta all'aggiunta alla schermata Home. Le icone si generano offline con `python tools/generate_icons.py`; serve Pillow **solo per rigenerarle**, non per eseguire LightDome.

## Installazione iPhone

1. Servire la build Flutter Web da un host locale affidabile, raggiungibile dall'iPhone. Non è stato creato né richiesto un host cloud.
2. Aprire quell'indirizzo in Safari iOS, scegliere **Condividi → Aggiungi alla schermata Home** quando disponibile.
3. Collegare l'iPhone alla stessa rete della cupola, poi inserire `lightdome.local` o IP in **Altro → Connessione**.
4. Verificare concretamente su Safari iOS l'apertura standalone, le icone, il tema, la connessione e il comportamento dopo riavvio.

**Limiti importanti:** un normale URL `http://lightdome.local` serve la WebUI embedded dell'ESP8266, **non** la build Flutter Web. I browser limitano service worker, cattura audio di sistema e molte API ai contesti sicuri HTTPS/localhost. Una pagina Flutter servita in HTTPS può non poter comunicare con `http://lightdome.local` per **mixed content** e vincoli di accesso alla LAN. Perciò manifest e icone non equivalgono a una PWA offline pienamente funzionale né garantiscono controllo su Safari: la combinazione host/origine/rete deve essere verificata, senza aggiungere ora proxy/cloud fragili.

## Stato delle verifiche

- Asset statici e meta tag generati e controllabili senza iPhone.
- Test widget Flutter per layout mobile e tema chiaro/scuro, build Web release e APK debug.
- **Da fare su iPhone reale**: aggiunta Home, startup standalone, connettività HTTP, permessi locali, sleep/background e cambio rete.
