# Shou · 收

**Tidy up. That’s it.**

[English](README.md) · [简体中文](README.zh-CN.md) · 繁體中文 · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

原生 macOS 清理工具，透過可檢視、可重複使用的規則，整理應用程式與開發專案。

> **狀態：設計階段。** 應用程式與 CLI 尚未推出；以下描述規劃中的功能。README 譯文不代表應用程式已支援該語言。

## 為什麼選擇 Shou

Rust `target`、Node.js 相依套件、專案快取及個人建置輸出，可能讓一台 500 GB 的 Mac 頻繁面臨空間不足。不同專案的目錄用途各異，光憑名稱或大小無法判斷能否清理。

Shou 將經過檢視的清理方式保存為個人規則：**找出占用 → 了解用途 → 定義規則 → 預覽 → 確認 → 再次使用。** 現有規則格式能表達的調整不需等待應用程式更新；引擎新增能力仍需升級。

## 規劃中的能力

- **專案空間分析**：在明確選取的工作區中，區分建置產物、已安裝相依套件、原始碼與未分類資料。
- **個人規則**：設定路徑、專案標記、保留條件與排除項目，預覽實際影響。
- **獨立雙入口**：原生桌面介面與 CLI 共用核心，各自完成規則管理、掃描、計畫與清理紀錄查詢。
- **方便現有 Agent 操作**：Codex、Claude Code、WorkBuddy 等可透過穩定 CLI 與 JSON 加入停用的規則草稿。Shou 不接入模型，也不開發或託管 Agent。
- **原生架構**：Swift、SwiftUI 與 AppKit；monorepo 共享可移植核心，未來 Windows 需獨立實作與驗證。

## 清理前先檢視

規則不能擴大作業系統權限。草稿必須經過驗證與預覽；啟用規則不等於授權刪除。每次執行都需要針對具體計畫確認，CLI 不提供略過確認的參數。

預設移到垃圾桶；永久移除本次清理項目需要另外確認，不清空其他垃圾桶內容。移入垃圾桶的容量與磁碟實際可用空間分開呈現。`node_modules` 屬於需要高度審閱的相依套件，不視為一般快取；名稱、鎖定檔與時間條件都不能保證可重建。

## 文件與參與

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md) · [國際化規範（英文）](docs/product/internationalization.md)

目前倉庫包含設計文件、規則合同草案與範例，尚無可下載程式。歡迎透過 [Issues](https://github.com/limecloud/shou/issues) 提供已去除敏感資訊的使用情境，或協助校對翻譯。

## 鳴謝

- [Mole](https://github.com/tw93/mole)：開發者終端工作流程與多語言專案呈現。
- [Pulse](https://pulse.egoist.dev/)：原生 macOS 資訊組織與空間概覽。
- [BuhoCleaner](https://www.drbuho.com/buhocleaner)：磁碟瀏覽與清理結果分組。

感謝以上專案帶來的產品與設計啟發；鳴謝不代表專案關聯或程式碼相依關係。

## 授權條款

[Apache License 2.0](LICENSE)。
