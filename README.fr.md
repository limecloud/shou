<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Un peu plus de place sur votre Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Un nettoyeur macOS natif pour les caches, les projets de développement et les dossiers qui grossissent. Visualisez l’espace utilisé, vérifiez votre sélection et réutilisez vos règles.

## Téléchargement et installation

Shou v0.11.0 nécessite **macOS 14 ou ultérieur**. L’app universelle fonctionne sur Apple Silicon et Intel. Glissez **Shou.app** de l’image disque vers **Applications**. L’interface est en anglais et chinois simplifié.

[**Shou v0.11.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.11.0/Shou-0.11.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.11.0/Shou-0.11.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.11.0/shou-0.11.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases) · [Windows 11 x64 (.zip)](https://github.com/limecloud/shou/releases/download/v0.11.0/Shou-0.11.0-windows-x64.zip)

Cette version est signée ad-hoc et non notariée par Apple. Si le premier lancement est bloqué, vérifiez la source puis consultez **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

## Les fonctions de Shou

| | |
| --- | --- |
| **Désinstallation** | Examiner une app et ses fichiers précisément associés avant de la supprimer. Les données personnelles exigent un accord distinct ; les composants déplacés sont restaurables. |
| **Éléments de démarrage** | Consulter les définitions de démarrage et ouvrir les réglages macOS des éléments de connexion. Shou ne les active ni ne les désactive. |
| **Exclusions** | Protéger des dossiers globalement ou par projet. Les règles modifiées sont enregistrées dans une nouvelle version désactivée. |
| **Caches des applications** | Examinez ensemble les caches de Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat et autres apps. |
| **Développement et projets** | Repérez les caches npm, Cargo, Xcode, Python et Go, Rust target, les dépendances Node.js et les produits Swift. |
| **Analyse de l’espace** | Explorez les dossiers avec une carte arborescente et une liste. |
| **Règles personnelles** | Créez des règles pour les dossiers régénérables, prévisualisez-les et réutilisez-les. |
| **Historique et restauration** | Consultez les résultats, restaurez des éléments ou confirmez leur suppression définitive séparément. |
| **Mises à jour en ligne** | Vérifiez les mises à jour dans les réglages ou le menu Shou. Leur signature est contrôlée avant installation. |

## Nettoyer en trois étapes

1. **Analyser.** Choisissez les apps ou ajoutez un espace de travail. L’analyse ne supprime rien.
2. **Vérifier.** Examinez les chemins, tailles, risques et conditions de régénération.
3. **Confirmer.** Déplacez la sélection vers la corbeille. Restaurez-la depuis l’historique au besoin.

La corbeille ne libère pas immédiatement d’espace. La suppression définitive est distincte et irréversible. Les contenus protégés, exclusions, apps et compilations actives peuvent bloquer le nettoyage.

## Vos fichiers, votre choix

Les règles sont locales et n’exécutent pas de commandes Shell. Aucun compte, connexion à un modèle ou scan cloud requis. Règles et historique restent sur votre Mac.

## Depuis le terminal

La CLI indépendante gère règles, analyses, plans et historique. Nettoyage et restauration nécessitent une confirmation interactive.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Documentation et contributions

Consultez la documentation pour compiler, tester et utiliser les règles ou la CLI. Signalez problèmes et suggestions dans Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Remerciements

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Licence

[Apache License 2.0](LICENSE).
