# macOS 调查要点

- 检查 Library 的 Application Support、Containers、Group Containers、Caches，以及 .codex、.local、项目 .dev/releases、SDK 的直属压缩包；它们均可能混有持久数据，不对父目录套删除规则。
- 微信/QQ 缓存、聊天记录和附件分开。保留应用清数据与卸载是不同任务，确认精确账户和范围，核实应用及助手退出；Shou 没有对应专用能力时交回产品审阅，不直接删除容器。
- Codex 按用户选择的保留期分析；会话、认证、技能、设置和 worktree 各有用途，不能按整个 .codex 的 mtime 过滤。
- Rust 离线文档可通过已发现的组件能力单独审阅；保留编译器和 targets。安装包存在不证明展开后的工具可重建，需核对版本、来源与用途。
- Docker Desktop/Colima 内部回收不等于宿主归还空间。只使用当前后端支持的操作，不手删稀疏磁盘、不自动压缩活动镜像。
- Shou 记录使用 records 预览和受控回收；显示保护原因与配额，恢复记录和活动计划不能当垃圾。不要清理自身记录目录绕过依赖检查。
