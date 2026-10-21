<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Ein bisschen mehr Platz auf deinem Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Ein nativer macOS-Cleaner für App-Caches, Entwicklungsprojekte und wachsende Ordner. Speicherverbrauch ansehen, die Auswahl prüfen und eigene Regeln wiederverwenden.

## Download und Installation

Shou v0.9.0 benötigt **macOS 14 oder neuer**. Die Universal-App läuft auf Apple Silicon und Intel Macs. Ziehe **Shou.app** aus dem Disk-Image nach **Applications**. Die Oberfläche ist auf Englisch und vereinfachtem Chinesisch verfügbar.

[**Shou v0.9.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.9.0/Shou-0.9.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.9.0/Shou-0.9.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.9.0/shou-0.9.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

Diese Version ist ad-hoc signiert und nicht von Apple notarisiert. Bei blockiertem Erststart prüfe die Downloadquelle und anschließend **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen**.

## Das kann Shou

| | |
| --- | --- |
| **Apps deinstallieren** | App und eindeutig zugehörige Dateien vor dem Entfernen prüfen. Persönliche Daten erfordern eine separate Zustimmung; verschobene Komponenten sind wiederherstellbar. |
| **Startobjekte** | Startdefinitionen prüfen und die macOS-Anmeldeobjekte öffnen. Shou aktiviert oder deaktiviert keine Einträge. |
| **Ausschlüsse** | Ordner global oder pro Projekt schützen. Geänderte eigene Regeln werden als deaktivierte neue Version gespeichert. |
| **App-Caches** | Caches von Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat und weiteren Apps gemeinsam prüfen. |
| **Entwicklung und Projekte** | Caches von npm, Cargo, Xcode, Python und Go sowie Rust target, Node.js-Abhängigkeiten und Swift-Builds finden. |
| **Speicheranalyse** | Ordnergrößen mit einer Treemap und einer Verzeichnisliste erkunden. |
| **Eigene Regeln** | Regeln für erneut erzeugbare Ordner erstellen, prüfen und wiederverwenden. |
| **Verlauf und Wiederherstellung** | Ergebnisse ansehen, Elemente wiederherstellen oder das endgültige Entfernen separat bestätigen. |
| **Online-Updates** | In den Einstellungen oder im Shou-Menü suchen. Signaturen werden vor der Installation geprüft. |

## In drei Schritten aufräumen

1. **Scannen.** App-Bereinigung wählen oder einen Projektordner hinzufügen. Der Scan entfernt keine Dateien.
2. **Prüfen.** Pfade, Größen, Risiken und Voraussetzungen zur Neuerstellung ansehen.
3. **Bestätigen.** Die Auswahl in den Papierkorb verschieben und bei Bedarf über den Verlauf wiederherstellen.

Der Papierkorb gibt nicht sofort Speicher frei. Endgültiges Entfernen erfordert eine separate Bestätigung und ist nicht umkehrbar. Geschützte Inhalte, Ausschlüsse sowie laufende Apps und Builds können die Bereinigung blockieren.

## Deine Dateien, deine Entscheidung

Regeln laufen lokal ohne Shell-Befehle. Kein Konto, keine Modellverbindung und kein Cloud-Scan nötig. Regeln und Verlauf bleiben auf deinem Mac.

## Im Terminal verwenden

Die unabhängige CLI verwaltet Regeln, Scans, Pläne und Verlauf. Bereinigung und Wiederherstellung benötigen eine interaktive Bestätigung.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Dokumentation und Beiträge

Builds, Tests, Regeln und CLI-Nutzung stehen in der Dokumentation. Fehler und Vorschläge sind in Issues willkommen.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Danksagungen

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Lizenz

[Apache License 2.0](LICENSE).
