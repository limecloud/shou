Shou v0.3.0 adds a guided personal-rule workflow, startup-item controls, and safer workspace identity handling.

- Create personal rules with a guided scope, marker, size, age, exclusion, rebuild, and limitation review. The read-only preview explains each match and saves a disabled draft until you explicitly enable it.
- Inspect startup definitions, search their names and paths, control current-user LaunchAgents with an explicit confirmation, and open macOS Login Items settings for other sources.
- Review applications and their exact associated files, including only shared group containers verified by macOS metadata. Personal data still requires separate consent; components restore independently from History.
- Preserve workspace bindings across a benign volume remount while refusing replaced roots, and keep cleanup plans tied to current identity and configuration evidence.
- Manage global and project exclusions, inspect recorded original and Trash locations, select history items in batches, and stop operations at recorded safe boundaries.
- Signed online updates, English and Simplified Chinese interfaces, and README guides in 11 languages.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel.

Download the DMG and drag Shou.app to Applications. The ZIP contains the same app. Verify downloads with SHA256SUMS. Existing Shou installations can use Check for Updates.

Adding global exclusions upgrades the local configuration format. Older Shou releases cannot read the upgraded configuration, even after the last global exclusion is removed.

This release is ad-hoc signed and is not Apple-notarized. If macOS blocks the initial launch, verify the download source and review System Settings → Privacy & Security. Sparkle independently verifies signed update archives and feeds.

简体中文：v0.3.0 新增个人规则向导与只读预览、当前用户 LaunchAgent 启停控制、卷重挂载后的工作区身份保护，以及经系统元数据确认的共享组容器卸载。个人数据需单独同意，已移动组件可独立恢复；更新包和订阅会在安装前验证签名。支持 macOS 14+、Apple Silicon 与 Intel；此版本尚未经过 Apple 公证。
