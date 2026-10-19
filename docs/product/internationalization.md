# Internationalization and localization

English | [简体中文](../zh-CN/product/internationalization.md)

Status: design draft. Documentation translations and runtime language support have separate evidence and release requirements.

## 1. Objectives

Provide global developers with consistent product information, rule explanations, and cleanup confirmation. English is the default public documentation language. Machine contracts remain language-independent; native interfaces follow system language and formatting conventions.

## 2. Language matrix

| Language | Documentation tag | Platform language | README | Technical docs | Application and CLI |
| --- | --- | --- | --- | --- | --- |
| English | `en` | `en` | Default | Default | Initial target; unimplemented |
| 简体中文 | `zh-CN` | `zh-Hans` | Localized | Complete edition | Initial target; unimplemented |
| 繁體中文 | `zh-TW` | `zh-Hant` | Localized | As needed | Enable after reviewed resources and tests |
| 日本語 | `ja` | `ja` | Localized | As needed | Enable after reviewed resources and tests |
| 한국어 | `ko` | `ko` | Localized | As needed | Enable after reviewed resources and tests |
| Deutsch | `de` | `de` | Localized | As needed | Enable after reviewed resources and tests |
| Français | `fr` | `fr` | Localized | As needed | Enable after reviewed resources and tests |
| Español | `es` | `es` | Localized | As needed | Enable after reviewed resources and tests |
| Português (Brasil) | `pt-BR` | `pt-BR` | Localized | As needed | Enable after reviewed resources and tests |
| Русский | `ru` | `ru` | Localized | As needed | Enable after reviewed resources and tests |
| Українська | `uk` | `uk` | Localized | As needed | Enable after reviewed resources and tests |

Advertise only existing documentation links. Actual runtime languages are declared by capability discovery and release notes, never inferred from README availability.

## 3. Documentation maintenance

- `README.md` is English; `README.<locale>.md` provides localized overviews.
- `docs/` contains English technical documentation; `docs/zh-CN/` mirrors its paths in Simplified Chinese.
- Link translations back to English with repository-relative links.
- Use illustrative projects and capacity ranges, with no conversational references, personal paths, or unattributed measurements.
- Synchronize command names, IDs, fields, states, safety boundaries, and requirement identifiers.
- Add languages through separately reviewed files, not duplicated machine schemas.
- Update translations with product changes. Identify stale editions; do not release known ambiguity in destructive-operation instructions.

## 4. Desktop localization

Use macOS String Catalogs (`.xcstrings`), English as development language, and system/app-specific language preferences. Use full strings, placeholders, and plural rules rather than concatenated sentences.

Localize numbers, dates, times, and capacity formatting without changing the defined decimal measurement basis. Preserve paths, filenames, rule IDs, and object IDs. Test longer translations, pseudo-localization, accessibility text, and narrow layouts. Review Simplified and Traditional Chinese independently.

Keep layout direction adaptable for future right-to-left languages without claiming current support. Windows uses native resource mechanisms with equivalent semantics; `.xcstrings` is not its runtime format.

## 5. CLI and machine output

Human-language precedence: `--locale` → saved application language → effective system locale → English. Normalize supported aliases such as `en_US.UTF-8`, `zh_CN.UTF-8`, and `zh-Hans`. Reject unknown explicit locale values; fall back to English for an unsupported system locale.

Locale changes affect only human-readable prompts and explanations. Command names, arguments, IDs, JSON keys, error codes, enums, statuses, byte integers, UTC ISO 8601 timestamps, matching, and safety decisions remain invariant. Readable JSON messages may be localized; automation must inspect stable codes rather than parse text.

Interactive confirmation uses the displayed language but binds the same plan digest. Execution must never depend on parsing a localized message.

## 6. Rule text

Rule matching and risk enums are language-independent. Shared examples use English base text; personal rules may contain Unicode in any language. Shou does not perform model-based translation.

Do not duplicate execution definitions per language. Localized template resources associate with stable rule IDs and versions; missing translations fall back to original text. A language switch does not change original rule bytes, its digest, or its execution scope.

## 7. Terminology

| English | Simplified Chinese | Meaning |
| --- | --- | --- |
| Workspace | 工作区 | Explicitly selected or registered root |
| Rule | 规则 | Declarative matching and conditions |
| Preset | 方案 | Selection logic, never standing deletion permission |
| Plan | 计划 | A concrete current scope and action |
| Preview | 预览 | Read-only review before execution |
| Build artifacts | 构建产物 | Distinct from source and unique deliverables |
| Installed dependencies | 已安装依赖 | Not all treated as caches |
| Move to Trash | 移到废纸篓 | Does not imply immediately available space |
| Permanently remove | 永久移除 | Separately confirmed irreversible action |
| Execution receipt | 执行记录 | Item-level operation facts and state |

## 8. Acceptance

Every released runtime language covers navigation, errors, risks, confirmation, restoration, missing permissions, partial scans, and accessibility labels. Test pluralization, long text, non-Latin paths, time zones, and locale aliases.

The same plan must retain its ID, digest, candidates, and decisions across English and Simplified Chinese. Additional languages require translation review and interaction tests. Documentation availability does not count as runtime validation.
