Shou v0.4.0 adds interactive space analysis, bundled AI rule-authoring Skills, automatic project discovery, and explicitly confirmed permanent cleanup.

- Analyze a local disk or folder, browse its size-sorted list and treemap, navigate and filter directories, use Quick Look, and select explicit files or directories for removal.
- Review exact paths before deleting permanently or choosing Move to Trash. Completed items update the displayed tree; Trash restoration and separately confirmed purge remain available in History. Permanent deletion cannot be undone.
- Customize cleanup with your existing AI agent. Install the bundled rule-authoring Skill for Codex or Claude Code, export a ZIP for WorkBuddy, or copy a prepared request with the exact CLI path and selected workspace. Shou does not launch external agents or call models.
- Discover developer projects automatically and remember extra scan folders. Review scan locations from Settings alongside application caches and existing project workspaces.
- Use focused command help, machine-readable capability discovery, bundled Skill reads, and the new analysis CLI. The CLI installer can expose the app's bundled executable without copying its resources.
- Choose Trash or permanent mode for rule-based cleanup, with exact-scope confirmation and per-item history. Noninteractive clients can prepare and inspect plans; destructive CLI execution still requires terminal confirmation.
- Signed online updates, English and Simplified Chinese interfaces, and download guides in 11 languages.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel.

Download the DMG and drag Shou.app to Applications. The ZIP contains the same app. Verify downloads with SHA256SUMS. Existing Shou installations can use Check for Updates.

Adding global exclusions upgrades the local configuration format. Older Shou releases cannot read the upgraded configuration, even after the last global exclusion is removed.

This release is ad-hoc signed and is not Apple-notarized. If macOS blocks the initial launch, verify the download source and review System Settings → Privacy & Security. Sparkle independently verifies signed update archives and feeds.

简体中文：v0.4.0 新增磁盘与文件夹空间分析，支持列表、矩形树图、导航筛选、快速查看及明确选择文件后移除；新增内置 AI 规则编写 Skill，可为 Codex／Claude Code 安装或导出供 WorkBuddy 导入。自动发现开发项目，并记住额外扫描目录。规则清理和空间分析支持分别确认的永久删除或移到废纸篓，永久删除无法撤销；非交互客户端不能绕过终端确认。更新包和订阅会在安装前验证签名。支持 macOS 14+、Apple Silicon 与 Intel；此版本尚未经过 Apple 公证。
