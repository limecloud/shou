# Windows 调查要点

- 路径以当前用户的 Known Folders、LocalAppData、RoamingAppData 和实际安装登记为准，不猜 C 盘、用户名称或把 macOS 路径替换成 Windows 路径。
- 区分用户缓存、聊天附件、应用包、安装器维护缓存、恢复文件和持久工具数据。Windows Installer、WinSxS、系统保护目录、恢复分区、pagefile/hiberfil 不作为普通文件清理目标。
- NTFS/ReFS 的硬链接、稀疏文件、压缩与重解析点影响计量；不跟随 junction，不跨用户、卷或未知挂载。回收站与永久删除分别解释。
- Docker/WSL 的 VHDX 是活动状态容器；删除内部缓存不会保证文件立即收缩。识别当前后端与发行版，压缩需要独立适配、关闭状态核验和当前授权，不能直接删除 VHDX。
- 开发目录应检查 bin/obj、构建输出、NuGet/npm/Cargo 缓存、SDK 压缩包、历史测试部署与旧工具组件。Git 跟踪、手改依赖、活跃构建和唯一离线包保持保护。
- 通过 capabilities 核实当前清理、数据库、工具和技能安装能力。available=false 或 native_acceptance_pending 必须交回支持的流程，不能使用 PowerShell 绕过产品门禁。
