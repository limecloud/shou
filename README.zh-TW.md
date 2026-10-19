<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>給 Mac，多留一點空間。</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

原生 macOS 清理工具，整理應用程式快取、開發專案與不斷增大的資料夾。看清空間去向，確認清理範圍，將個人規則留到下次。

## 下載與安裝

Shou v0.2.0 支援 **macOS 14 以上版本**，通用版本適用於 Apple Silicon 與 Intel Mac。開啟磁碟映像，將 **Shou.app** 拖入 **Applications**。介面提供英文與簡體中文。

[**Shou v0.2.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.2.0/shou-0.2.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

此版本使用 ad-hoc 簽章，未經 Apple 公證。如首次啟動遭阻擋，確認下載來源後，前往**系統設定 → 隱私權與安全性 → 強制打開**。

## Shou 的功能

| | |
| --- | --- |
| **應用程式移除** | 先檢視應用程式及明確關聯的檔案，再確認移除。個人資料須另外同意，移至垃圾桶的元件可復原。 |
| **啟動項目** | 檢視啟動項目定義並開啟 macOS 登入項目設定；Shou 不直接啟用或停用項目。 |
| **排除規則** | 在全域或個別專案中保護資料夾；個人規則修改後會儲存為停用的新版本。 |
| **應用程式快取** | 集中檢視 Chrome、Edge、Firefox、Codex、Claude、QQ、微信等快取。 |
| **開發工具與專案** | 尋找 npm、Cargo、Xcode、Python、Go 快取，以及 Rust target、Node.js 相依套件與 Swift 建置產物。 |
| **空間分析** | 透過矩形樹圖與目錄清單逐層檢視資料夾大小。 |
| **個人規則** | 為可重新產生的資料夾建立規則，預覽後重複使用。 |
| **歷史與還原** | 檢視結果、還原選取項目，或另行確認永久移除本次清理項目。 |
| **線上更新** | 從設定或 Shou 選單檢查更新，安裝前驗證套件簽章。 |

## 三步整理空間

1. **掃描。** 選擇應用程式清理或加入工作區；掃描不會刪除檔案。
2. **檢視。** 確認路徑、大小、風險與重新產生的條件。
3. **確認。** 將選取項目移至垃圾桶，需要時從歷史記錄還原。

移至垃圾桶不會立即釋放空間。永久移除須另外確認且無法復原。受保護內容、排除規則及執行中的應用程式或建置可能阻止清理。

## 檔案由你決定

規則在本機執行，不執行 Shell 命令。無需帳號、模型連線或雲端掃描；規則與歷史記錄保存在 Mac 上。

## 終端機使用

獨立 CLI 可管理規則、掃描、計畫與歷史記錄；清理及還原須互動確認。

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## 文件與參與

建置、測試、規則與 CLI 用法請見文件。歡迎透過 Issues 提供問題與建議。

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## 致謝

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## 授權條款

[Apache License 2.0](LICENSE).
