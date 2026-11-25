# Registratore

App open source per macOS che registra le tue call: cattura insieme il microfono e l'audio del Mac (Zoom, Teams, Meet, WhatsApp, ecc.), crea un unico file audio e, se vuoi, trascrive la conversazione separando "Io" e "Altri".

- Gratuita, nessuna dipendenza esterna, nessun account.
- Tutto resta sul tuo Mac: niente server, niente statistiche d'uso.
- Nel Dock e nella barra dei menu.

> **Prima di usarla leggi [Uso responsabile](#uso-responsabile).**

## Requisiti

- macOS 14 (Sonoma) o successivo
- Xcode Command Line Tools: `xcode-select --install`

## Installazione

L'app si installa compilandola dal codice sorgente: non è distribuita già pronta perché non è firmata con un certificato Apple Developer.

```bash
git clone https://github.com/ceribbo/registratore.git
cd registratore
./crea-certificato.sh   # una volta sola, vedi sotto
./build.sh
cp -R "Registratore.app" /Applications/
open "/Applications/Registratore.app"
```

`crea-certificato.sh` crea nel tuo portachiavi un certificato personale ("Registratore Firma Locale") usato per firmare l'app. Senza, l'app viene firmata in modo provvisorio e macOS richiede di nuovo i permessi a ogni ricompilazione. Puoi rimuoverlo quando vuoi da Accesso Portachiavi.

Per aggiornare: `git pull`, poi di nuovo `./build.sh` e la copia in Applicazioni.

## Primo avvio: permessi

Al primo avvio l'app mostra un avviso sull'uso responsabile. Al primo "Avvia registrazione" macOS chiede:

1. **Microfono**: consenti.
2. **Registrazione schermo e audio di sistema**: abilita "Registratore" in Impostazioni di Sistema > Privacy e sicurezza, poi chiudi e riapri l'app. Serve solo per l'audio: il video non viene registrato.
3. **Riconoscimento vocale**: consenti, se usi la trascrizione.
4. **Cartella Documenti**: consenti.

Per la trascrizione serve la **Dettatura** di macOS: attivala in Impostazioni di Sistema > Tastiera > Dettatura e aggiungi la lingua che ti serve. Così il modello viene scaricato sul Mac e la trascrizione avviene in locale.

Se dopo una ricompilazione i permessi sembrano già dati ma l'app continua a chiederli, azzerali e concedili di nuovo:

```bash
tccutil reset All studio.micelio.registratore
```

## Uso

Dalla finestra o dall'icona nella barra dei menu: "Avvia registrazione" e "Ferma". Durante la registrazione l'icona nel Dock mostra "REC".

In `Documenti/Registratore/<data ora>/` trovi:

| File | Contenuto |
|---|---|
| `registrazione.m4a` | mix di microfono e audio del Mac |
| `trascrizione.txt` | dialogo con orari, "Io" e "Altri" (se la trascrizione è attiva) |

Prima del mix voce e call vengono portate automaticamente allo stesso volume, così la tua voce non risulta più bassa degli altri.

Le tracce separate servono solo durante l'elaborazione e vengono eliminate. Restano (`voce.m4a`, `call.m4a`) solo se il mix non riesce, per non perdere l'audio.

### Fonti

- **Microfono**: attivalo o disattivalo e scegli il dispositivo (predefinito, microfono del Mac, AirPods, USB, ecc.).
- **Migliora la voce** (attivo di default): applica al microfono l'elaborazione vocale di macOS, la stessa delle app di videochiamata (volume automatico, riduzione del rumore e dell'eco). Funziona con il microfono predefinito di sistema.
- **Audio del Mac**: attivalo o disattivalo e scegli se registrare tutte le app o solo quella della call, così notifiche e musica restano fuori.

### Lingue

L'interfaccia è in italiano. La trascrizione supporta italiano e inglese.

### Consigli

- Usa le cuffie: con le casse il microfono riprende anche la voce degli altri, che compare due volte.
- Con "Tutte le app" viene registrato tutto l'audio del Mac: per evitarlo scegli solo l'app della call.
- La trascrizione di una call lunga può richiedere alcuni minuti.

## Uso responsabile

Registrare conversazioni è soggetto a regole che cambiano da Paese a Paese. In alcuni ordinamenti si può registrare una conversazione a cui si partecipa; in altri (per esempio diversi Stati degli USA) serve il consenso di tutti i partecipanti. Anche dove la registrazione è permessa, diffonderla o usarla oltre i propri scopi legittimi può violare la privacy altrui (per esempio il GDPR nell'Unione Europea).

Usando questo software:

- sei l'unico responsabile delle registrazioni che fai e di come le usi;
- ti impegni a rispettare le leggi applicabili, a informare gli altri partecipanti e a ottenerne il consenso quando richiesto;
- non registri conversazioni a cui non partecipi.

Gli autori non forniscono consulenza legale e non sono responsabili dell'uso che viene fatto del software.

## Privacy

- Registrazioni e trascrizioni vengono salvate solo sul tuo Mac, in `Documenti/Registratore`.
- L'app non invia dati agli autori né a terzi e non raccoglie statistiche d'uso.
- La trascrizione usa il riconoscimento vocale di Apple. Se il modello locale della Dettatura non è installato, l'audio può essere inviato ai server Apple secondo la [privacy policy di Apple](https://www.apple.com/legal/privacy/).

## Licenza

[MIT](LICENSE): il software è fornito "così com'è", senza garanzie di alcun tipo.
