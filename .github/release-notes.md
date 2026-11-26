Shou v0.25.0 adds dedicated storage cleanup for Shou itself and Docker on macOS.

- Shou storage review can remove published scan indexes and explicitly selected finished cleanup history, including its file lists and summaries. Active, recoverable and uncertain records, settings and credentials stay protected.
- Docker storage reviews stopped containers, unreferenced images, unused build cache and ordinary local volumes separately. Volumes require explicit data consent; running containers and referenced data are kept. Exact identities and live references are checked before each owner operation.
- Running Colima VZ profiles can reclaim virtual-disk space through an optional online TRIM after cleanup, or without deleting Docker objects. The VM stays running. Logical capacity, allocated disk space and observed host free-space changes are displayed separately.
- Space Analysis and Large Files link to the dedicated reviews. Ordinary file deletion protects Docker data directories. Uncertain Docker operations cannot replay automatically; unsupported disk backends and offline compaction remain unavailable.
- Progress text updates without layout animation. Unknown and known progress reserve the same space, preventing the percentage, path and stop button from jumping during cleanup.
- macOS downloads retain Developer ID signing, Apple notarization and signed updates. npm registry publication remains separate from this GitHub release.

macOS 14 or later; Apple Silicon and Intel. Download the DMG or ZIP for the app, or the standalone CLI archive. Windows 11 x64/ARM64 downloads remain unsigned self-contained previews; public cleanup, uninstall and startup mutation gates remain closed.

简体中文：Shou v0.25.0 为 macOS 增加自身存储和 Docker 专项清理。

- Shou 存储可清理已发布的扫描索引，并显式选择删除已完成历史及其文件清单、摘要；活动、可恢复和结果不确定的记录，以及设置和凭据继续保留。
- Docker 存储分别审阅停止的容器、未引用镜像、闲置构建缓存和普通本地卷。卷数据单独同意，保留运行中的容器及被引用的数据；每项通过所属工具执行前核对确切身份和当前引用。
- 已运行的 Colima VZ 支持清理后可选在线 TRIM，也可单独回收磁盘空间；虚拟机保持运行。分别展示逻辑容量、磁盘实际占用和期间宿主可用空间变化。
- 空间分析与大文件页提供专项入口，普通文件删除保护 Docker 数据目录。结果不确定的操作不能自动重放，不开放未适配后端及离线磁盘压缩。
- 修复清理过程中的文字闪动：百分比直接更新，未知和已知进度占用相同空间，路径与停止按钮保持稳定。
- macOS 下载沿用 Developer ID 签名、Apple 公证和签名更新；npm registry 发布独立于本次 GitHub Release。

支持 macOS 14 及以上、Apple Silicon 和 Intel。应用下载 DMG 或 ZIP，终端使用独立 CLI 归档。Windows 11 x64／ARM64 保持未签名自包含便携预览，清理、卸载和启动项变更的公开门禁保持关闭。
