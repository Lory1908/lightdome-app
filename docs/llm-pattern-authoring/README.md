# LightDome — authoring di pattern da LLM

Un LLM produce soltanto un **oggetto JSON dichiarativo**. Non si eseguono script, espressioni, HTML o comandi prodotti da un LLM. La conversione locale non richiede Internet né librerie extra.

## Campi e unità

- `preset`: `breath` (respiro), `pulse` (battito), `sunrise` (alba), `random` (organico).
- `duration`: secondi per ciclo, numero tra 1 e 20.
- `minimum` e `maximum`: intensità percentuale; rispettivamente 0..90 e 10..100, sempre minimum <= maximum.
- `duty`: percentuale di tempo acceso del battito, 5..95. Presente anche negli altri preset per schema comune.
- `easing`: `smooth` morbido, `sine` naturale, `linear` lineare, `sharp` netto.
- `randomness`: irregolarità percentuale 0..100, usata da `random`.
- `loop`: ripetizione del file, bool.
- `autorun`: riavvio automatico, bool; l'impostazione viene applicata solo quando il file sarà caricato esplicitamente.

Lo schema JSON è `recipe.schema.json`, gli esempi sono in `examples/`, e il prompt per il modello è `PROMPT.md`. Il codice Python applica le stesse condizioni con stdlib (nessuna dipendenza `jsonschema`).

## Validazione e conversione

Da PowerShell, nella root del repository:

```powershell
python docs/llm-pattern-authoring/ldy_recipe.py validate docs/llm-pattern-authoring/examples/breath.json
python docs/llm-pattern-authoring/ldy_recipe.py convert docs/llm-pattern-authoring/examples/breath.json respiro.ldy
python -m unittest discover -s docs/llm-pattern-authoring/tests -v
```

`convert` stampa sempre una preview ASCII **prima** di creare il file. Nessun upload automatico e nessuna modifica al firmware. Controllare l'effetto prima di salvare sulla cupola; la visualizzazione ASCII è approssimativa e non una prova fisica. Tutti i nuovi file sono `LDY1` con **250 Hz**, uint16 little-endian 0..1023 e metadati JSON compatibili con l'editor WebUI/Flutter. I file legacy senza metadati restano accettati dal firmware.

La conversione non interpreta testo non JSON, non usa `eval` e rifiuta chiavi sconosciute, NaN/Infinity, valori fuori range e input troppo grandi. Non pubblicare/caricare automaticamente output generati da un LLM.
