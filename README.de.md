# Shou · 收

**Tidy up. That’s it.**

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · Deutsch · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

Ein nativer macOS-Cleaner mit nachvollziehbaren, wiederverwendbaren Regeln für Entwicklungsprojekte und Anwendungen.

> **Status: Entwurfsphase.** Anwendung und CLI sind noch nicht verfügbar. Die folgenden Funktionen sind geplant. Eine übersetzte README bedeutet nicht, dass die Anwendung diese Sprache bereits unterstützt.

## Warum Shou?

Rust-`target`-Verzeichnisse, Node.js-Abhängigkeiten, Projekt-Caches und eigene Build-Ausgaben können den Speicher eines Macs mit 500 GB immer wieder füllen. Verzeichnisse haben je nach Projekt unterschiedliche Aufgaben. Name und Größe allein sagen nicht, ob sie entfernt werden können.

Shou macht aus geprüften Aufräumentscheidungen persönliche Regeln: **Finden → Verstehen → Regel definieren → Vorschau → Bestätigen → Wiederverwenden.** Änderungen innerhalb des bestehenden Regelformats benötigen kein App-Update. Neue Fähigkeiten der Engine erfordern weiterhin ein Upgrade.

## Geplante Funktionen

- **Speicheranalyse pro Projekt:** Build-Artefakte, installierte Abhängigkeiten, Quellcode und nicht zugeordnete Daten in ausdrücklich ausgewählten Arbeitsbereichen unterscheiden.
- **Persönliche Regeln:** Pfade, Projektmerkmale, Aufbewahrungsbedingungen und Ausnahmen definieren; Ziele und Risiken vorab prüfen.
- **Unabhängige Oberfläche und CLI:** Gemeinsamer Kern für Regelverwaltung, Scans, Pläne und Verlauf; beide Zugänge funktionieren eigenständig.
- **Schnittstellen für vorhandene Agents:** Codex, Claude Code, WorkBuddy und ähnliche Werkzeuge können über eine stabile CLI und JSON deaktivierte Regelentwürfe hinzufügen. Shou bindet keine Modelle ein und entwickelt oder betreibt keine Agents.
- **Native Architektur:** Swift, SwiftUI und AppKit. Ein portabler Kern im Monorepo; Windows benötigt später eine eigene Implementierung und Validierung.

## Vor dem Aufräumen prüfen

Regeln erweitern keine Betriebssystemrechte. Entwürfe werden validiert und in einer Vorschau geprüft. Das Aktivieren einer Regel ist keine Löschfreigabe. Jeder Lauf benötigt die Bestätigung eines konkreten Plans; die CLI bietet keinen Schalter zum Überspringen dieser Bestätigung.

Standardmäßig werden Elemente in den Papierkorb verschoben. Das endgültige Entfernen dieses Aufräumvorgangs muss separat bestätigt werden; andere Papierkorbinhalte bleiben unberührt. Verschobene Datenmenge und tatsächlich verfügbarer Speicher werden getrennt ausgewiesen. `node_modules` sind sorgfältig zu prüfende Abhängigkeiten, keine gewöhnlichen Caches. Namen, Lockdateien und Altersbedingungen garantieren keine Wiederherstellbarkeit durch Neuaufbau.

## Dokumentation und Beiträge

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md) · [Internationalisierung (Englisch)](docs/product/internationalization.md)

Das Repository enthält derzeit Entwürfe, einen vorläufigen Regelvertrag und Beispiele. Es gibt noch keinen App-Download. Über [Issues](https://github.com/limecloud/shou/issues) sind konkrete Anwendungsfälle ohne vertrauliche Daten und Verbesserungen an Übersetzungen willkommen.

## Danksagung

- [Mole](https://github.com/tw93/mole): Terminal-Abläufe für Entwickler und mehrsprachige Projektpräsentation.
- [Pulse](https://pulse.egoist.dev/): Native macOS-Informationsgestaltung und Speicherübersichten.
- [BuhoCleaner](https://www.drbuho.com/buhocleaner): Datenträgererkundung und gruppierte Aufräumergebnisse.

Vielen Dank für die Anregungen zu Produkt und Design. Diese Danksagung bedeutet weder eine Zusammenarbeit noch eine Code-Abhängigkeit.

## Lizenz

[Apache License 2.0](LICENSE).
