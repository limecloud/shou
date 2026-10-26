Shou v0.16.0 adds native, read-only system monitoring and desktop resource summaries on macOS and Windows.

- Eight resource panels cover load, CPU, GPU, memory, battery, system-volume space and disk IO, network IO, and thermals/fans. Real two-minute trends and a searchable process table use the current workspace gradient and shared design values.
- Opt-in macOS menu-bar and Windows notification-area menus show resource readings and the top three CPU processes. Commands open monitoring, pause/resume, disable the summary, and quit normally. Dock and native Windows taskbar Jump List tasks open monitoring directly, including the unpackaged Windows app.
- One serial sampler serves the page and summary. Warmup, pause, sleep, source changes and failures reset rate baselines. Process identity includes start time; CPU uses total machine capacity. History stays in memory, with no process termination, sensor controls or automatic startup.
- Unsupported or unreadable sensors stay unavailable. macOS reads supported fixed AppleSMC sensors; Windows uses supported read-only APIs and does not install a temperature driver. Neither platform fabricates health scores or missing measurements.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed update metadata and checksums. The app uses an ad-hoc signature and is not Apple-notarized. Windows downloads remain unsigned, self-contained x64/ARM64 portable previews for Windows 11; public cleanup, uninstall and startup mutation gates stay closed. Complete Windows UI/accessibility, broad hardware compatibility, signing, installation and updating remain separate acceptance work. GitHub publication does not publish packages to npm. The existing v0.15.0 tag and assets are preserved.

简体中文：Shou v0.16.0 新增 macOS／Windows 原生只读系统监控及桌面资源摘要。

- 八个面板展示负载、CPU、GPU、内存、电池、系统卷空间与磁盘读写、网络收发、温度与风扇；两分钟真实趋势与可搜索进程表沿用当前工作台渐变和共享设计值。
- 主动开启的 macOS 菜单栏／Windows 托盘展示资源读数与前三个 CPU 进程，支持打开监控、暂停／继续、关闭摘要及正常退出。Dock 与原生 Windows 任务栏 Jump List 可直接打开监控，便携版同样支持。
- 页面和摘要共用串行采样。首次读取、暂停、休眠、来源变化及失败后重建速率基线；进程以 PID 和开始时间共同标识，CPU 按整机容量计量。历史只留在内存，不提供终止进程、传感器控制或开机常驻。
- 不可读或不支持的传感器保持缺失；macOS 读取受支持的固定 AppleSMC 传感器，Windows 使用只读系统 API，不安装温度驱动。两端均不编造健康分数或未知读数。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新元数据和校验和；应用为 ad-hoc 签名，未经 Apple 公证。Windows 继续提供 Windows 11 的未签名 x64／ARM64 自包含便携预览，公开清理、卸载和启动项变更门禁保持关闭；完整界面／辅助功能、广泛硬件兼容、签名、安装与更新分别验收。GitHub 发布不会自动发布 npm 包。保留既有 v0.15.0 标签和附件。
