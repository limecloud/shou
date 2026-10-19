Shou v0.2.0 adds application uninstall and more control over cleanup on your Mac.

- Review applications and their exact associated files, then move selected components to Trash. Personal data requires separate consent; restore components independently from History.
- Inspect startup definitions, search their names and paths, and open macOS Login Items settings. Shou does not enable or disable startup items.
- Manage global and project exclusions, and save personal-rule changes as disabled revisions for review.
- Inspect recorded original and Trash locations, select history items in batches, and stop operations at recorded safe boundaries.
- Improved keyboard navigation, context menus, selection, progress, and reduced-motion support.
- Signed online updates, English and Simplified Chinese interfaces, and README guides in 11 languages.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel.

Download the DMG and drag Shou.app to Applications. The ZIP contains the same app. Verify downloads with SHA256SUMS. Existing v0.1.0 installations can use Check for Updates.

Adding global exclusions upgrades the local configuration format. Older Shou releases cannot read the upgraded configuration, even after the last global exclusion is removed.

This release is ad-hoc signed and is not Apple-notarized. If macOS blocks the initial launch, verify the download source and review System Settings → Privacy & Security. Sparkle independently verifies signed update archives and feeds.

简体中文：v0.2.0 新增应用卸载与关联文件审阅、启动项查看、全局及项目排除规则、个人规则版本编辑、历史位置核验与批量选择，并改进键盘操作、右键菜单和停止控制。个人数据需单独同意，已移动组件可独立恢复。启动项仅查看，不直接启停。v0.1.0 可通过“检查更新”升级。添加全局排除规则后，旧版本无法读取升级的配置。支持 macOS 14+、Apple Silicon 与 Intel；此版本尚未经过 Apple 公证。
