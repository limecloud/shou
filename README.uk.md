<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Трохи більше місця на вашому Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Нативне очищення macOS для кешів, проєктів і папок, що зростають. Перегляньте використання місця, перевірте вибір і збережіть свої правила.

## Завантаження та встановлення

Shou v0.2.0 потребує **macOS 14 або новішої**. Універсальна програма працює на Apple Silicon та Intel. Перетягніть **Shou.app** з образу диска до **Applications**. Інтерфейс доступний англійською та спрощеною китайською.

[**Shou v0.2.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.2.0/shou-0.2.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

Версія має підпис ad-hoc і не нотаризована Apple. У разі блокування запуску перевірте джерело та відкрийте **Системні параметри → Приватність і безпека**, щоб дозволити запуск.

## Можливості Shou

| | |
| --- | --- |
| **Видалення програм** | Перегляньте програму й точно пов’язані файли перед видаленням. Особисті дані потребують окремої згоди; компоненти з Кошика можна відновити. |
| **Автозапуск** | Переглядайте визначення запуску та відкривайте параметри об’єктів входу macOS. Shou не вмикає й не вимикає їх. |
| **Виключення** | Захищайте папки глобально або в окремому проєкті. Змінені правила зберігаються як нова вимкнена версія. |
| **Кеші програм** | Переглядайте разом кеші Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat та інших програм. |
| **Розробка та проєкти** | Знаходьте кеші npm, Cargo, Xcode, Python і Go, Rust target, залежності Node.js та продукти Swift. |
| **Аналіз місця** | Досліджуйте папки за допомогою деревної карти й списку каталогів. |
| **Власні правила** | Створюйте правила для відновлюваних папок, перевіряйте й використовуйте повторно. |
| **Історія та відновлення** | Переглядайте результати, відновлюйте елементи або окремо підтверджуйте остаточне видалення. |
| **Онлайн-оновлення** | Перевіряйте оновлення в параметрах або меню Shou. Підпис перевіряється перед встановленням. |

## Очищення за три кроки

1. **Сканування.** Виберіть програми або додайте робочий простір. Файли не видаляються.
2. **Перевірка.** Перегляньте шляхи, розміри, ризики та умови відтворення.
3. **Підтвердження.** Перемістіть вибране до Смітника. За потреби відновіть через історію.

Смітник не звільняє місце відразу. Остаточне видалення потребує окремого підтвердження й незворотне. Захищений вміст, виключення, активні програми та збирання можуть блокувати очищення.

## Ваші файли — ваше рішення

Правила локальні й не виконують команди Shell. Обліковий запис, моделі та хмарне сканування не потрібні. Правила й історія залишаються на Mac.

## Робота з термінала

Незалежний CLI керує правилами, скануванням, планами й історією. Очищення та відновлення потребують інтерактивного підтвердження.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Документація та участь

Збирання, тести, правила й CLI описано в документації. Повідомляйте про помилки й пропозиції через Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Подяки

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Ліцензія

[Apache License 2.0](LICENSE).
