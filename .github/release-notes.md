Shou v0.24.0 redesigns cleanup review around the largest locations and adds a bundled cleanup assistant for existing AI clients.

- Review exact cleanup locations in descending size order, with recommendations, decisions, protected items and items kept for this scan. Scans start without selections; filters preserve selections and kept items stay out of recommendations.
- Keep purpose, full paths, rebuild impact and blocking evidence close to each item. Find more large items through space analysis without expanding cleanup scope.
- Separate processed-size estimates from the signed available-space change on each volume. Missing measurements and unrelated writes are not presented as reclaimed space.
- Review Shou's own derived records by collection, size and retention reason. Keep the latest scan when needed and recheck the exact reviewed inventory before collection. Windows preserves all plans, configuration, execution/recovery records and referenced scans.
- Install the bundled shou-cleanup-assistant or shou-rule-authoring Skill into Codex or Claude Code, or export a ZIP for another client. Local edits are preserved and managed updates are backed up. The assistant uses current Shou capabilities and confirmation; it does not bypass unavailable operations.
- Remove offline Rust documentation separately from compilers and targets on macOS. Windows follows the cleanup-review, record-maintenance and Skill-distribution contracts; tool-specific actions depend on platform capabilities.

PostgreSQL database deletion, Docker volume deletion and host virtual-disk compaction have no new automatic execution entry point in this release. Interactive appearance and complete preview journeys remain separate acceptance scopes.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. Release packaging requires Developer ID signatures and Apple notarization; replacing an older ad-hoc installation may require granting Full Disk Access again. Windows x64/ARM64 downloads are unsigned, self-contained previews for Windows 11. Native fixture checks, interactive preview journeys, UAC, ARM64 interaction, signing, installation and updates are separate acceptance scopes. npm registry publication is verified separately from GitHub assets.

简体中文：Shou v0.24.0 围绕大项占用重新设计清理审阅，并为现有 AI 客户端提供随包辅助清理技能。

- 具体清理位置按占用倒序排列，支持建议清理、需要判断、受保护和本次保留。扫描完成默认不勾选，筛选保留已有选择，推荐排除保留项。
- 在对象附近显示用途、完整路径、重建影响和阻断依据；通过空间分析查找更多大项，不扩大清理范围。
- 分开显示处理量估算和每个卷期间可用空间的正负变化，缺测或其他写入不冒充已回收空间。
- 按集合、占用和保留原因审阅 Shou 派生记录，可选择保留最新扫描，并在清理前重新核对本次精确清单。Windows 保留全部计划、配置、执行／恢复记录及被引用扫描。
- 可将随包 shou-cleanup-assistant 辅助清理或 shou-rule-authoring 规则编写技能安装到 Codex、Claude Code，或导出 ZIP。保留本地改动，受管更新先备份；助手使用 Shou 当前能力与确认入口，不绕过不可用操作。
- macOS 可单独移除 Rust 离线文档，保留编译器与目标平台。Windows 同步清理审阅、记录维护和技能分发，工具专属操作按平台实际能力提供。

本版未新增 PostgreSQL 数据库删除、Docker 卷删除或宿主虚拟磁盘压缩的自动执行入口。明暗外观及完整预览版交互旅程仍需单独验收。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和。发布打包要求 Developer ID 签名及 Apple 公证；替换旧的临时签名安装可能需要重新授予完全磁盘访问权限。Windows 提供 Windows 11 未签名 x64／ARM64 自包含便携预览。原生夹具、预览版界面旅程、UAC、ARM64 交互、签名、安装与更新分别验收；npm registry 与 GitHub 附件分别验证。
