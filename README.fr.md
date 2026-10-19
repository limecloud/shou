# Shou · 收

**Tidy up. That’s it.**

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · Français · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

Un outil de nettoyage natif pour macOS, avec des règles vérifiables et réutilisables pour les projets de développement et les applications.

> **État : phase de conception.** L’application et la CLI ne sont pas encore disponibles. Les fonctionnalités ci-dessous sont prévues. La traduction du README ne signifie pas que l’application prend déjà en charge cette langue.

## Pourquoi Shou ?

Les répertoires Rust `target`, les dépendances Node.js, les caches de projets et les fichiers générés peuvent saturer régulièrement un Mac de 500 Go. Le rôle d’un répertoire varie selon le projet : son nom ou sa taille ne suffit pas à déterminer s’il peut être supprimé.

Shou transforme une décision de nettoyage vérifiée en règle personnelle : **Repérer → Comprendre → Définir une règle → Prévisualiser → Confirmer → Réutiliser.** Les changements exprimables dans le format de règles existant ne nécessitent pas de mise à jour de l’application. De nouvelles capacités du moteur exigent toujours une mise à niveau.

## Fonctionnalités prévues

- **Analyse par projet** : distinguer les fichiers générés, les dépendances installées, le code source et les données non classées dans les espaces de travail explicitement sélectionnés.
- **Règles personnelles** : définir chemins, marqueurs de projet, conditions de conservation et exclusions, puis examiner les éléments concernés et les risques.
- **Interface de bureau et CLI indépendantes** : un même cœur pour gérer les règles, analyser, préparer les plans et consulter l’historique, avec deux points d’entrée autonomes.
- **Interfaces pour les agents existants** : Codex, Claude Code, WorkBuddy et des outils similaires peuvent ajouter des brouillons de règles désactivés via une CLI stable et du JSON. Shou n’intègre aucun modèle et ne développe ni n’héberge d’agent.
- **Architecture native** : Swift, SwiftUI et AppKit. Un cœur portable partagé dans un monorepo ; Windows nécessitera une implémentation et une validation distinctes.

## Vérifier avant de nettoyer

Les règles ne peuvent pas étendre les autorisations du système. Les brouillons doivent être validés et prévisualisés ; activer une règle n’autorise aucune suppression. Chaque exécution exige la confirmation d’un plan précis. La CLI ne propose pas d’option pour ignorer cette confirmation.

Par défaut, les éléments vont dans la Corbeille. Supprimer définitivement les éléments de cette opération exige une confirmation séparée, sans vider les autres éléments de la Corbeille. Le volume déplacé et l’espace réellement disponible sont affichés séparément. `node_modules` contient des dépendances qui exigent un examen attentif, pas de simples caches. Noms, fichiers de verrouillage et ancienneté ne garantissent pas une reconstruction possible.

## Documentation et contributions

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md) · [Internationalisation (anglais)](docs/product/internationalization.md)

Le dépôt contient actuellement des documents de conception, un contrat de règles provisoire et des exemples. Aucun téléchargement de l’application n’est disponible. Les [Issues](https://github.com/limecloud/shou/issues) accueillent les cas concrets sans informations confidentielles et les améliorations de traduction.

## Remerciements

- [Mole](https://github.com/tw93/mole) : flux de travail en terminal pour les développeurs et présentation multilingue du projet.
- [Pulse](https://pulse.egoist.dev/) : organisation native des informations sur macOS et synthèses de l’espace disque.
- [BuhoCleaner](https://www.drbuho.com/buhocleaner) : exploration du disque et regroupement des résultats de nettoyage.

Merci à ces projets pour leurs inspirations produit et design. Ces remerciements n’impliquent ni affiliation ni dépendance de code.

## Licence

[Apache License 2.0](LICENSE).
