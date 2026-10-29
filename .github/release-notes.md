Shou v0.22.0 fixes authorized space analysis, improves scan scope and application review, and reduces repeated cleanup work.

- Fix an optimized macOS build error that generated the wrong temporary index path and prevented authorized space analysis from completing.
- Keep one administrator session available beyond 10,000 requests. Cancelled or lost authorization requires an explicit recovery action instead of repeated password or UAC prompts. Restarting Shou starts a new session.
- Choose standard cleanup, a local disk or a folder. Standard discovery includes actual home folders, while saved rules, exclusions and explicit scan boundaries remain enforced.
- Preserve application selections during component review and permission recovery. Offer normal quit and rescan for running applications, and review verified broken macOS application links separately from application data.
- Reduce duplicate scan records, manifest encoding and history writes while retaining exact manifests, identity checks and item results. Cleanup progress stays within selected targets and hides paths while saving results.
- Improve software-update icons and simplify shared permission and cleanup presentation. Windows source follows the same session, scope and selection contracts; public mutation gates remain closed in the portable preview.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized; Full Disk Access may need to be granted again after replacement. Windows x64/ARM64 downloads are unsigned, self-contained previews for Windows 11. Native fixture checks, interactive preview journeys, UAC, ARM64 interaction, signing, installation and updates are separate acceptance scopes. npm registry publication is verified separately from GitHub assets.

简体中文：Shou v0.22.0 修复管理员空间分析，完善扫描范围和应用审阅，并减少清理中的重复处理。

- 修复 macOS 优化构建生成错误临时索引路径，导致管理员空间分析无法完成的问题。
- 管理员会话不再因累计请求超过 10,000 次而退出。取消或失效后由用户主动恢复，避免反复弹出密码或 UAC 窗口；重新启动 Shou 后建立新会话。
- 清理支持标准范围、本地磁盘和指定文件夹。标准发现覆盖实际用户目录，继续遵守保存的规则、排除项及明确扫描边界。
- 应用组件审阅和权限恢复保留所选范围。运行中的应用可正常退出后重新扫描，已核实失效的 macOS 应用链接可与应用数据分别审阅。
- 减少重复扫描记录、清单编码和历史写入，保留完整清单、身份核验和逐项结果。清理进度仅显示所选目标，保存结果时隐藏路径。
- 完善软件更新图标，精简权限与清理界面。Windows 源码同步会话、范围和选择合同，便携预览的公开变更门禁保持关闭。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和。应用为 ad-hoc 签名，未经 Apple 公证，替换后可能需要重新授予完全磁盘访问权限。Windows 提供 Windows 11 未签名 x64／ARM64 自包含便携预览。原生夹具、预览版界面旅程、UAC、ARM64 交互、签名、安装与更新分别验收；npm registry 与 GitHub 附件分别验证。
