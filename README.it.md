# PC Diagnostics

[English](README.md) · **Italiano**

Strumento di diagnosi per PC Windows, in un solo file e in sola lettura. Si avvia come amministratore, si sceglie l'analisi e dopo pochi minuti si ottiene un report in linguaggio semplice, in italiano e in inglese, che dice che cosa non va nel computer e che cosa fare. Crea anche uno ZIP con tutti i dati grezzi per il tecnico.

È pensato per help desk e assistenza IT. Chi è davanti al PC deve solo avviarlo e inviare lo ZIP. Il report è scritto in modo da essere comprensibile anche per chi non è del mestiere.

## Caratteristiche principali

- **Un solo file, niente da installare.** `PC-Diagnostics.bat` è un ibrido batch/PowerShell che usa il Windows PowerShell già presente in Windows.
- **Da Windows 7 SP1 a Windows 11** (Windows PowerShell da 2.0 a 5.1). I comandi più recenti vengono usati solo se esistono. Altrimenti lo strumento ripiega su WMI, registro di sistema e comandi classici.
- **Sola lettura.** Non modifica impostazioni, driver, chiavi di registro o file di sistema (vedere [Che cosa modifica e che cosa no](#che-cosa-modifica-e-che-cosa-no)).
- **Giudizi, non solo dati.** Ogni area riceve un esito a semaforo. Quando i dati non bastano per un giudizio sicuro, l'esito è 🔵 *Incerto* invece di un'ipotesi.
- **Spiega gli arresti anomali.** I codici delle schermate blu vengono tradotti in linguaggio semplice, con la causa probabile (disco, memoria, driver, scheda video, alimentazione…). Gli spegnimenti improvvisi vengono distinti dagli spegnimenti con Avvio rapido la cui sessione non è stata ripresa e dalle sospensioni interrotte da una perdita di corrente; ogni arresto viene collocato nel tempo rispetto all'accensione o al risveglio.
- **Report in due lingue**, in HTML (si apre in qualsiasi browser e si può stampare) e in Markdown.

## Che cosa controlla

| Area | Dati raccolti |
|---|---|
| Computer | Modello, numero di serie, processore, scheda video, RAM, versione ed età del BIOS, edizione e build di Windows, data di installazione, ultimo avvio, Secure Boot, dominio o gruppo di lavoro, versioni precedenti di Windows. Sui computer HP, le impostazioni del BIOS rilevanti. |
| Disco / SSD | Stato di salute, previsione guasti SMART, temperatura, usura, ore di accensione, errori di lettura/scrittura non corretti, spazio libero, file system da riparare ("dirty"), TRIM, controller Intel RST/VMD. Errori del disco e NTFS dai registri eventi, attribuiti al disco di sistema o ad altri dischi (chiavette USB, schede di memoria). |
| Memoria RAM | Moduli installati, esiti del test della memoria di Windows, errori di memoria segnalati dall'hardware (WHEA), episodi di memoria esaurita. |
| Arresti anomali | Schermate blu e spegnimenti improvvisi con i codici di errore decodificati, indicati come intervallo tra l'ultimo segno di vita e l'accensione successiva. Ogni arresto viene classificato: a computer acceso, durante la sospensione o il risveglio, durante lo spegnimento, ripresa non riuscita, oppure sessione dell'Avvio rapido non ripresa dopo uno spegnimento regolare (indicata a parte, non come arresto). Inoltre: spegnimenti forzati con il pulsante, arresti subito dopo l'accensione o il risveglio, sospensioni interrotte da una perdita di corrente e riprese dal disco (non lasciano un evento di arresto), mancanza di corrente subito prima di un arresto, minidump, report di Segnalazione errori Windows, problemi nella configurazione del salvataggio dei crash, log di ripristino dell'avvio. |
| Programmi, servizi, dispositivi | Chiusure inattese dei programmi (quelli più frequenti), errori dei servizi, servizi automatici fermi, attività pianificate non riuscite, dispositivi con errori in Gestione dispositivi, blocchi del driver della scheda video (TDR), dispositivi USB non riconosciuti, segnalazioni del kernel (live dump) decodificate dal file di dump o dal report WER, errori hardware WHEA. |
| Alimentazione e batteria | Salute della batteria (capacità attuale rispetto a quella di progetto), passaggi tra corrente e batteria, sospensioni interrotte e riprese dal disco, spegnimenti con Avvio rapido non ripresi, stato massimo del processore nel piano energetico, Avvio rapido, report della batteria e report energetico di Windows. |
| Prestazioni e temperature | Utilizzo, frequenza e limite del processore imposto dal BIOS, RAM in uso, attività del disco, temperature delle zone termiche e rallentamenti per calore, campionati ogni 5 secondi. Programmi che usano più memoria. |
| Rete | Schede di rete (IP, gateway, DNS), raggiungibilità di router e Internet (ping e porta TCP 443), risoluzione dei nomi, impostazioni proxy, errori di Wi-Fi, TCP/IP, DNS e DHCP nei registri. |
| Sicurezza | Antivirus e relative definizioni (Centro sicurezza, Microsoft Defender), profili del Windows Firewall (anche se impostati da criteri di gruppo) e firewall di terze parti, BitLocker, TPM, riavvio in sospeso, tentativi di accesso non riusciti per tipo. |
| Aggiornamenti e software | Aggiornamenti di Windows installati, aggiornamenti non riusciti e ancora mancanti, giorni dall'ultimo aggiornamento, stato del servizio Windows Update, programmi installati di recente, programmi all'avvio. |

I registri eventi vengono analizzati per gli **ultimi 60 giorni**, oppure dall'inizio del registro se copre un periodo più breve. In quel caso il report indica il periodo reale.

## Requisiti

- Windows 7 SP1, 8, 8.1, 10 o 11
- Windows PowerShell 2.0 o successivo (incluso in tutte queste versioni)
- Un account **amministratore**: molti registri e contatori hardware si leggono solo con i privilegi elevati

## Avvio rapido

1. Scaricare `PC-Diagnostics.bat` dall'[ultima release](../../releases/latest), oppure aprire il file in questo repository e fare clic su **Download raw file**.
2. Se Windows blocca il file perché proviene da Internet: clic destro > **Proprietà** > spuntare **Annulla blocco** > **OK**.
3. Clic destro su `PC-Diagnostics.bat` > **Esegui come amministratore**.
4. Confermare il sistema operativo rilevato con **Invio**, oppure sceglierne un altro.
5. Scegliere l'analisi e premere **Invio**:

   | Analisi | Durata | Che cosa fa |
   |---|---|---|
   | **Normal** | circa 5 minuti | Tutti i controlli standard. |
   | **Stress** | circa 12 minuti | Controlli standard più il processore al 100% per 10 minuti, per verificare raffreddamento e alimentazione. Salvare prima il lavoro e collegare l'alimentatore. Chiede conferma (Y/N; anche S è accettato). |
   | **DeepScan** | fino a 20 minuti | Controlli standard più una verifica in sola lettura dei file di sistema di Windows (`sfc /verifyonly`) e del file system del disco (`chkdsk` senza opzioni di riparazione). |

   Tasti del menu: **↑ / ↓** spostarsi · **tasti numerici** selezionare · **Invio** confermare · **Esc** uscire.

6. Alla fine la console mostra un riepilogo e si apre la cartella dei risultati. Fare doppio clic su `REPORT_IT.html` (o `REPORT_EN.html`) per leggere il report.

La finestra può essere ridotta a icona durante l'analisi. Il computer non va in sospensione fino alla fine e un clic nella finestra non mette in pausa il programma.

### Quale sistema operativo scegliere

| Scelta | Metodi usati |
|---|---|
| Windows 7 | Solo metodi compatibili (WMI, registro, comandi classici). Funziona con PowerShell 2.0. Si può scegliere anche su sistemi più recenti per forzare la modalità compatibile. |
| Windows 8 / 8.1 | Metodi compatibili più i comandi più recenti di Windows 8, quando disponibili. |
| Windows 10 / 11 | Tutti i controlli, compresi i contatori di salute del disco e lo stato di Defender, che richiedono i comandi più recenti. |

## Risultati

I risultati vengono salvati sul Desktop dell'utente che ha effettuato l'accesso, anche quando i diritti di amministratore provengono da un altro account. Se il Desktop non è scrivibile, finiscono in `C:\PC-Diagnosis`.

```text
PC-Diagnosis_<COMPUTER>_<AAAAMMGG_hhmmss>\
├── REPORT_IT.html / REPORT_EN.html        il report (doppio clic per aprirlo nel browser)
├── REPORT_IT.md   / REPORT_EN.md          lo stesso report in Markdown
├── run_log.txt                            log di esecuzione
├── data\                                  dati grezzi: file CSV, registri eventi (.evtx), dump dei crash,
│                                          segnalazioni errori, report batteria ed energetico, output di sfc/chkdsk
└── PC-Diagnosis_<COMPUTER>_<...>.zip      tutto quanto sopra, pronto da inviare all'assistenza
```

Il report ha 13 sezioni: risultato in breve, cosa fare, il computer, disco e spazio, memoria RAM, arresti anomali e riavvii improvvisi, programmi/servizi/dispositivi, alimentazione e batteria, prestazioni e temperature, rete, sicurezza, aggiornamenti e software, limiti dell'analisi.

| Report | Console | Significato |
|---|---|---|
| 🟢 OK | `OK` | Nessun problema rilevato. |
| 🟡 Da verificare | `CHECK` | Un aspetto da tenere d'occhio. |
| 🔴 Problema | `PROBLEM` | Da risolvere. |
| 🔵 Incerto | `UNSURE` | I dati non bastano per un giudizio sicuro. Il dettaglio spiega perché e che cosa verificare. |
| ⚪ Non valutabile | `N/A` | L'informazione non è disponibile su questo computer. |

> [!WARNING]
> Il report e lo ZIP contengono informazioni identificative e riservate: nome del computer, numero di serie, indirizzi IP, software installato, registri eventi e dump dei crash (che possono contenere frammenti della memoria). Condividerli solo con chi si occupa dell'assistenza del computer.

## Uso da riga di comando e automatico

Da un Prompt dei comandi aperto come amministratore, indicare l'analisi come primo argomento per saltare i menu:

```bat
PC-Diagnostics.bat normal|stress|deepscan [win7|win8|win10|win11] [quick]
```

| Argomento | Significato |
|---|---|
| `normal`, `stress`, `deepscan` | Analisi da eseguire. Obbligatorio per l'uso automatico. |
| `win7`, `win8`, `win10`, `win11` | Profilo da usare. Il valore predefinito è il sistema rilevato. `win7` forza i metodi compatibili su qualsiasi versione. |
| `quick` | Esecuzione breve di prova: campionamento di 15 secondi e nessun report energetico. |

Variabili d'ambiente facoltative:

| Variabile | Effetto |
|---|---|
| `DIAG_OUT` | Cartella in cui creare la cartella dei risultati (provata prima del Desktop). |
| `DIAG_SAMPLE` | Durata del campionamento delle prestazioni in secondi (predefinita 120, oppure 600 in Stress). Ignorata con `quick`. |
| `DIAG_SKIPENERGY=1` | Salta il report energetico di 60 secondi. |

Esempi:

```bat
PC-Diagnostics.bat deepscan
PC-Diagnostics.bat normal win7
set DIAG_OUT=D:\Diagnostica
PC-Diagnostics.bat normal
```

Nell'uso automatico non viene chiesto nulla: **Stress parte senza conferma** e alla fine la cartella dei risultati non viene aperta. Quando lo script viene eseguito come SYSTEM, per esempio da uno strumento di gestione remota, impostare `DIAG_OUT` in modo che i risultati finiscano in una cartella nota.

## Che cosa modifica e che cosa no

Lo strumento non modifica impostazioni, driver, servizi, chiavi di registro o file di sistema e non ripara mai nulla: `chkdsk` viene eseguito senza `/f` e `sfc` con `/verifyonly`. Quando serve una riparazione, il report indica quale comando eseguire.

Durante l'esecuzione si limita a:

- scrivere la cartella dei risultati (più file temporanei in `%TEMP%`, eliminati alla fine);
- impedire che computer e schermo vadano in sospensione e disattivare la modalità QuickEdit nella propria finestra, così che un clic non metta in pausa il programma; entrambe le impostazioni vengono ripristinate alla fine;
- eseguire `powercfg /energy` (una traccia di 60 secondi) e `powercfg /batteryreport`;
- in modalità Stress, caricare tutti i thread del processore per 10 minuti.

Il traffico di rete si limita al test di connettività: due ping verso il gateway predefinito e due verso `1.1.1.1`, una risoluzione DNS di `www.microsoft.com` e un tentativo di connessione sulla porta TCP 443 (HTTPS) verso `www.microsoft.com` o `1.1.1.1`. **Nessun dato viene inviato:** i risultati restano sul computer finché non si decide di condividerli.

`-ExecutionPolicy Bypass` vale solo per il processo PowerShell avviato dallo script. Il criterio di esecuzione del sistema non viene modificato e un criterio impostato tramite Criteri di gruppo ha comunque la precedenza.

## Come funziona

`PC-Diagnostics.bat` è un file poliglotta batch/PowerShell. `cmd.exe` ignora la prima riga, mentre PowerShell la legge come l'inizio di un blocco di commento che nasconde i comandi batch. La parte batch avvia Windows PowerShell (la versione a 64 bit tramite `Sysnative`, anche quando lo script viene avviato da un processo a 32 bit), che rilegge lo stesso file ed esegue il codice PowerShell. Tutto lo strumento resta in un unico file di testo, leggibile prima di eseguirlo.

Alcuni antivirus considerano sospetti gli script che avviano PowerShell in questo modo. Il codice è tutto nel file: leggerlo prima di eseguirlo.

## Limiti

- I controlli sono automatici e si basano su ciò che Windows registra. Indicano dove cercare, ma non sostituiscono la verifica fisica del computer né i test hardware del produttore.
- Le temperature e alcuni contatori del disco dipendono da ciò che l'hardware espone. Molti computer non comunicano a Windows la temperatura reale del processore, e un valore alto che non cambia mai viene segnalato come incerto.
- Senza Stress le temperature vengono misurate con poco carico e sono poco indicative.
- Un `chkdsk` in sola lettura sul volume in uso può segnalare errori non reali. Il report li indica come incerti, a meno che altri dati non li confermino.
- L'output di alcuni strumenti di Windows (`sfc`, `chkdsk`, `fsutil`) viene riconosciuto in italiano e in inglese. Con altre lingue di visualizzazione questi esiti possono risultare incerti o non disponibili.
- Windows non registra l'ora esatta di un arresto, ma solo l'ultimo segno di vita prima dell'arresto e l'accensione successiva: il report indica questo intervallo.
- Una mancanza di corrente durante la sospensione, un computer spento a mano mentre è sospeso e un mancato risveglio lasciano le stesse tracce nei registri; lo stesso vale per una spina staccata e un alimentatore difettoso.
- Alcuni campi degli eventi usati per la classificazione (lo stato di sospensione nell'evento 41, l'ora salvata nell'evento 6008, il tipo di avvio nell'evento 27) non sono documentati da Microsoft: il loro significato è ricavato da valori documentati affini e verificato su registri reali.

## Contribuire

Segnalazioni (issue) e pull request sono benvenute. Prima di modificare lo script:

- Il codice deve essere interpretato ed eseguito da **Windows PowerShell 2.0 / .NET 3.5**: niente `-in`/`-notin`, `-shl`/`-shr`, `[ordered]`, `[pscustomobject]`, `::new()`, sintassi abbreviata `Where-Object Name`, `-File`/`-Directory`/`-Raw` o API di .NET 4. I cmdlet più recenti si usano solo dopo averne verificato l'esistenza (funzione `Has`).
- Il codice viene eseguito dentro uno script block: non usare variabili `$script:` e non riutilizzare, dentro i vari passaggi, i nomi delle variabili lette dalle funzioni di supporto (`$raw`, `$out`, `$log`, `$R`, `$Verdicts`, `$Actions`).
- Salvare il file in **UTF-8 senza BOM** con fine riga **CRLF**, altrimenti l'intestazione batch smette di funzionare. Il file `.gitattributes` del repository impedisce a Git di convertirlo.
- Lo strumento deve restare in sola lettura.
- Provare le modifiche sul maggior numero possibile di versioni di Windows, almeno con `PC-Diagnostics.bat normal quick`.

Quando si segnala un problema, allegare `run_log.txt` dalla cartella dei risultati, dopo aver controllato che non contenga nulla che non si vuole condividere.

## Licenza

Distribuito con [licenza MIT](LICENSE).

Il software è fornito "così com'è", senza garanzie di alcun tipo. La modalità Stress tiene il processore al massimo carico per 10 minuti: usarla solo su computer di cui si è responsabili, dopo aver salvato il lavoro aperto.
