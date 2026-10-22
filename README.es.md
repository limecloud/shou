<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Un poco más de espacio en tu Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Un limpiador nativo de macOS para cachés, proyectos de desarrollo y carpetas que crecen. Consulta el espacio, revisa la selección y reutiliza tus reglas.

## Descarga e instalación

Shou v0.11.0 requiere **macOS 14 o posterior**. La app universal funciona en Apple Silicon e Intel. Arrastra **Shou.app** de la imagen de disco a **Applications**. La interfaz está en inglés y chino simplificado.

[**Shou v0.11.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.11.0/Shou-0.11.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.11.0/Shou-0.11.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.11.0/shou-0.11.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

Esta versión tiene firma ad-hoc y no está notarizada por Apple. Si macOS bloquea el inicio, comprueba la fuente y consulta **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**.

## Qué puede hacer Shou

| | |
| --- | --- |
| **Desinstalar apps** | Revisar la app y los archivos vinculados antes de desinstalar. Los datos personales requieren consentimiento aparte; los componentes enviados a la Papelera se pueden restaurar. |
| **Elementos de inicio** | Consultar las definiciones de inicio y abrir los ajustes de inicio de sesión de macOS. Shou no activa ni desactiva elementos. |
| **Exclusiones** | Proteger carpetas globalmente o por proyecto. Las reglas modificadas se guardan como una nueva versión desactivada. |
| **Cachés de aplicaciones** | Revisa juntas las cachés de Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat y otras apps. |
| **Desarrollo y proyectos** | Detecta cachés npm, Cargo, Xcode, Python y Go, Rust target, dependencias Node.js y productos Swift. |
| **Análisis de espacio** | Explora carpetas con un mapa de árbol y una lista de directorios. |
| **Reglas personales** | Crea reglas para carpetas regenerables, comprueba resultados y reutilízalas. |
| **Historial y recuperación** | Consulta resultados, restaura elementos o confirma por separado su eliminación permanente. |
| **Actualizaciones en línea** | Busca desde Ajustes o el menú Shou. La firma se verifica antes de instalar. |

## Limpia en tres pasos

1. **Analiza.** Elige apps o añade un espacio de trabajo. El análisis no elimina archivos.
2. **Revisa.** Comprueba rutas, tamaños, riesgos y requisitos de regeneración.
3. **Confirma.** Mueve la selección a la Papelera; restáurala desde el historial si hace falta.

La Papelera no libera espacio inmediatamente. La eliminación permanente se confirma aparte y no se puede deshacer. Contenido protegido, exclusiones, apps y compilaciones activas pueden bloquear la limpieza.

## Tus archivos, tu decisión

Las reglas son locales y no ejecutan comandos Shell. No necesitas cuenta, modelos ni análisis en la nube. Reglas e historial permanecen en tu Mac.

## Uso desde el terminal

La CLI independiente gestiona reglas, análisis, planes e historial. Limpieza y recuperación requieren confirmación interactiva.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Documentación y contribuciones

Consulta la documentación para compilar, probar y usar reglas o la CLI. Envía problemas y sugerencias mediante Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Agradecimientos

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Licencia

[Apache License 2.0](LICENSE).
