# Shou · 收

**Tidy up. That’s it.**

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · Español · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

Una herramienta de limpieza nativa para macOS con reglas que se pueden revisar y reutilizar en proyectos de desarrollo y aplicaciones.

> **Estado: fase de diseño.** La aplicación y la CLI todavía no están disponibles. Las funciones siguientes están previstas. Un README traducido no significa que la aplicación ya admita ese idioma.

## ¿Por qué Shou?

Los directorios Rust `target`, las dependencias de Node.js, las cachés de proyectos y los archivos de compilación pueden llenar repetidamente un Mac de 500 GB. La función de cada directorio depende del proyecto: su nombre o tamaño no bastan para saber si se puede eliminar.

Shou convierte una decisión de limpieza revisada en una regla personal: **Encontrar → Comprender → Definir una regla → Previsualizar → Confirmar → Reutilizar.** Los cambios que permite el formato de reglas existente no requieren actualizar la aplicación. Las nuevas capacidades del motor sí requieren una actualización.

## Funciones previstas

- **Análisis por proyecto:** distinguir archivos de compilación, dependencias instaladas, código fuente y datos sin clasificar en espacios de trabajo seleccionados explícitamente.
- **Reglas personales:** definir rutas, marcadores de proyecto, condiciones de conservación y exclusiones; revisar los elementos afectados y los riesgos.
- **Escritorio y CLI independientes:** un núcleo compartido para gestionar reglas, analizar, preparar planes y consultar el historial desde cualquiera de las dos interfaces.
- **Interfaces para agentes existentes:** Codex, Claude Code, WorkBuddy y herramientas similares pueden añadir borradores de reglas desactivados mediante una CLI estable y JSON. Shou no integra modelos ni desarrolla o aloja agentes.
- **Arquitectura nativa:** Swift, SwiftUI y AppKit. Núcleo portable en un monorepo; Windows requerirá una implementación y validación propias más adelante.

## Revisar antes de limpiar

Las reglas no amplían los permisos del sistema operativo. Los borradores se validan y previsualizan; activar una regla no autoriza ninguna eliminación. Cada ejecución requiere confirmar un plan concreto. La CLI no ofrece opciones para omitir esa confirmación.

Por defecto, los elementos se trasladan a la Papelera. Eliminar permanentemente los elementos de esta operación exige otra confirmación y no vacía otros contenidos de la Papelera. El volumen trasladado y el espacio realmente disponible se muestran por separado. `node_modules` contiene dependencias que requieren una revisión cuidadosa, no simples cachés. Los nombres, archivos de bloqueo y condiciones de antigüedad no garantizan que los datos puedan regenerarse.

## Documentación y contribuciones

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md) · [Internacionalización (inglés)](docs/product/internationalization.md)

El repositorio contiene documentos de diseño, un contrato provisional de reglas y ejemplos. Todavía no hay una aplicación descargable. Las [Issues](https://github.com/limecloud/shou/issues) reciben casos concretos sin datos confidenciales y mejoras de traducción.

## Agradecimientos

- [Mole](https://github.com/tw93/mole): flujos de trabajo de terminal para desarrolladores y presentación multilingüe del proyecto.
- [Pulse](https://pulse.egoist.dev/): organización nativa de información en macOS y resúmenes del espacio disponible.
- [BuhoCleaner](https://www.drbuho.com/buhocleaner): exploración del disco y agrupación de los resultados de limpieza.

Gracias por la inspiración en producto y diseño. Estos agradecimientos no implican afiliación ni dependencia de código.

## Licencia

[Apache License 2.0](LICENSE).
