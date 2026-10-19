<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Чуть больше места на вашем Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Нативная очистка macOS для кэшей, проектов и растущих папок. Узнайте, куда уходит место, проверьте выбор и сохраните свои правила.

## Загрузка и установка

Shou v0.3.0 требует **macOS 14 или новее**. Универсальная версия работает на Apple Silicon и Intel. Перетащите **Shou.app** из образа диска в **Applications**. Интерфейс доступен на английском и упрощённом китайском.

[**Shou v0.3.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.3.0/Shou-0.3.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.3.0/Shou-0.3.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.3.0/shou-0.3.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

Версия подписана ad-hoc и не нотарифицирована Apple. При блокировке запуска проверьте источник и откройте **Системные настройки → Конфиденциальность и безопасность** для разрешения запуска.

## Возможности Shou

| | |
| --- | --- |
| **Удаление приложений** | Проверьте приложение и точно связанные файлы перед удалением. Личные данные требуют отдельного согласия; компоненты из Корзины можно восстановить. |
| **Автозагрузка** | Просматривайте определения запуска и открывайте настройки объектов входа macOS. Shou не включает и не отключает их. |
| **Исключения** | Защищайте папки глобально или в отдельном проекте. Изменённые правила сохраняются как новая отключённая версия. |
| **Кэши приложений** | Просматривайте вместе кэши Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat и других программ. |
| **Разработка и проекты** | Находите кэши npm, Cargo, Xcode, Python и Go, Rust target, зависимости Node.js и продукты Swift. |
| **Анализ места** | Изучайте папки с помощью карты дерева и списка каталогов. |
| **Личные правила** | Создавайте правила для восстанавливаемых папок, проверяйте и используйте повторно. |
| **История и восстановление** | Просматривайте результаты, восстанавливайте элементы или отдельно подтверждайте окончательное удаление. |
| **Онлайн-обновления** | Проверяйте обновления в настройках или меню Shou. Подпись проверяется перед установкой. |

## Очистка в три шага

1. **Сканирование.** Выберите приложения или добавьте рабочую папку. Файлы не удаляются.
2. **Проверка.** Изучите пути, размеры, риски и условия повторного создания.
3. **Подтверждение.** Переместите выбор в Корзину. При необходимости восстановите через историю.

Корзина не освобождает место сразу. Окончательное удаление требует отдельного подтверждения и необратимо. Защищённые данные, исключения, работающие приложения и сборки могут блокировать очистку.

## Ваши файлы — ваше решение

Правила локальны и не выполняют команды Shell. Учётная запись, модели и облачное сканирование не нужны. Правила и история остаются на Mac.

## Работа в терминале

Независимый CLI управляет правилами, сканированием, планами и историей. Очистка и восстановление требуют интерактивного подтверждения.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Документация и участие

Сборка, тесты, правила и CLI описаны в документации. Ошибки и предложения отправляйте через Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Благодарности

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Лицензия

[Apache License 2.0](LICENSE).
