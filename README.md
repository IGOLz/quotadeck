# QuotaDeck

Widget nativo per macOS che mostra la quota **residua** di Claude Code e Codex per
**tutti gli account** presenti sul Mac, sempre aggiornata.

<p>
  <img src="docs/light.png" width="300" alt="QuotaDeck, tema chiaro">
  <img src="docs/dark.png" width="300" alt="QuotaDeck, tema scuro">
</p>

- **Swift + SwiftUI/AppKit**, nessuna dipendenza: app da ~320 KB, CPU a 0% quando è inattiva.
- **Widget desktop** sempre visibile (trascinabile, su tutti gli Space) e icona nella **barra dei menu** con popover.
- Si aggiorna ogni 60 s (configurabile: 30 s / 1 / 2 / 5 min), al risveglio dal sonno e all'apertura del popover.

## Fonti dati

| Provider | Account | Endpoint |
|---|---|---|
| Claude Code | file in `auth-dir` di **CLIProxyAPI** (`~/.config/cliproxyapi/config.yaml` → `~/.config/cliproxyapi/auth/claude-*.json`). Il proxy rinnova i token, QuotaDeck li rilegge a ogni ciclo. | `GET api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json`, `~/.codex-*/auth.json`, `$CODEX_HOME`, più eventuali account `codex` in CLIProxyAPI | `GET chatgpt.com/backend-api/wham/usage` |

QuotaDeck usa i token **solo in lettura**: non li rinnova e non li scrive mai.

## Come leggere le card

- **Percentuale grande**: quota rimasta nella finestra (settimanale / 5 ore).
- **Tacca verticale** (solo settimanale): dove sarebbe la barra a un consumo costante. Se la barra
  finisce prima della tacca stai consumando più veloce del ritmo.
- **Reset ×N** (Codex): crediti di reset del rate limit disponibili.
- **Expires** (Codex): scadenza dell'abbonamento ChatGPT.
- **Updated…** in arancione: l'ultimo aggiornamento è fallito (passa il mouse per il motivo); i valori
  mostrati sono gli ultimi validi. Su HTTP 429 l'account viene ritentato dopo 5 minuti.

Passa il mouse su una card per vedere l'email dell'account. Clic destro sul widget: aggiorna,
tieni in primo piano, nascondi.

## Build e installazione

```sh
./scripts/build.sh            # crea build/QuotaDeck.app
./scripts/build.sh --install  # copia in ~/Applications e avvia
```

Richiede Xcode / Swift 6 e macOS 14+. Il bundle è firmato ad-hoc.
"Launch at Login" si attiva dal menu ⚙︎ del popover.

Render con dati reali senza avviare l'interfaccia:

```sh
build/QuotaDeck.app/Contents/MacOS/QuotaDeck --snapshot out.png [--dark]
```

## Perché non WidgetKit

I widget WidgetKit richiedono una firma con un team Apple Developer e il sistema limita i loro
aggiornamenti (circa ogni 15 minuti). Il widget di QuotaDeck è una finestra nativa al livello del
desktop disegnata dall'app stessa, quindi si aggiorna ogni volta che arrivano dati nuovi.
