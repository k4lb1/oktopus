# Oktopus

Ein Pixel-Oktopus, der zeigt, was Claude Code gerade tut: als Statuszeile im Terminal und als kleine Mac-App in der Notch.

- **Statuszeile** (`claude/statusline.sh`): Oktopus mit großen Augen plus Infospalte (Kontext, Limits, Cache, aktuelles Tool).
- **Hooks** (`claude/oktopus-hook.sh`): schreiben den Zustand jeder Sitzung nach `/tmp/oktopus-<session_id>`.
- **Notch-App** (`Sources/Oktopus`): zeigt die dringendste Sitzung, klopft bei Erlaubnisfragen, meldet „fertig“, klappt beim Drüberfahren zur Liste aller Sitzungen auf.

Die Figur wird nur in `statusline.sh` gezeichnet; die App lässt das Skript zeichnen und rechnet die Viertelblöcke in Pixel um.

## Einrichten

```bash
cp claude/statusline.sh claude/oktopus-hook.sh ~/.claude/
cp claude/graustufen.json ~/.claude/themes/
# statusLine und hooks aus claude/settings-auszug.json in ~/.claude/settings.json übernehmen
./bauen.sh   # baut ~/Applications/Oktopus.app
```

Rechtsklick auf den Oktopus: „Beim Anmelden starten“ oder „Beenden“.
