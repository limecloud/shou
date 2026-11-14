Shou v0.24.1 adds Developer ID signing and Apple notarization to macOS downloads.

- The universal app, standalone CLI and nested Sparkle components use the same Developer ID team, Hardened Runtime and trusted timestamps.
- Both the application and disk image pass Apple notarization, ticket stapling and Gatekeeper checks before distribution. ZIP archives contain the stapled app; update signatures and checksums cover final bytes.
- Native npm payloads are signed before their package hashes are recorded. npm registry publication remains separate from this GitHub release.
- Existing cleanup protections and explicit confirmation remain in force. Replacing an older ad-hoc installation may require granting Full Disk Access again.

macOS 14 or later; Apple Silicon and Intel. Download the DMG or ZIP for the app, or the standalone CLI archive. Windows 11 x64/ARM64 downloads remain unsigned self-contained previews; public cleanup, uninstall and startup mutation gates remain closed.

简体中文：Shou v0.24.1 为 macOS 下载增加 Developer ID 签名与 Apple 公证。

- 通用应用、独立 CLI 和 Sparkle 内部组件使用同一开发者团队签名，启用 Hardened Runtime 与可信时间戳。
- 应用和磁盘映像均通过 Apple 公证、票据装订与 Gatekeeper 检查后再分发。ZIP 包含已装订票据的应用，更新签名和校验和基于最终字节生成。
- 原生 npm 载荷先签名再记录包摘要；npm registry 发布独立于本次 GitHub Release。
- 保持原有清理保护和当前范围确认。替换旧的临时签名安装可能需要重新授予完全磁盘访问权限。

支持 macOS 14 及以上、Apple Silicon 和 Intel。应用下载 DMG 或 ZIP，终端使用独立 CLI 归档。Windows 11 x64／ARM64 保持未签名自包含便携预览，清理、卸载和启动项变更的公开门禁保持关闭。
