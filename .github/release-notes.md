Shou v0.15.0 introduces the new native workspace and read-only tools for understanding disk usage and application versions.

- Top task navigation, a continuous light/dark gradient, original task illustrations, full-width expandable rows and a stable selection footer follow the current shared design. Populated pages prioritize controls and results.
- Settings and CLI diagnostics produce a bounded report of capacity, access and record-directory safety. Reports omit personal paths and contents and are never uploaded automatically.
- Space analysis can compare two retained observations of the same folder. Identity, accounting and coverage checks distinguish measurable changes from missing, replaced or incomplete observations. Historical results never authorize deletion.
- Application details can explicitly check a supported public release catalog: six stable applications through Homebrew Cask on macOS, and registered Visual Studio Code x64 stable installations on Windows. Checks show versions, observation time and the official update page; they do not download or install updates.
- The CLI generates static Bash/Zsh completion; Windows also generates PowerShell completion. It does not modify shell profiles. macOS developer discovery prioritizes literal output paths and project markers in wide directories while retaining activity and exact-scope protection.

Both platforms have independent implementations of diagnostics, completion, comparison and catalog checks. Windows downloads are **unsigned portable previews for Windows 11**, with self-contained x64/ARM64 app and CLI ZIPs. Public cleanup, application uninstall and startup mutation gates remain closed. ARM64 runtime, complete UI/accessibility, native MSI/task acceptance, signing, installation and updating remain pending; cross-compilation and x64 startup checks do not establish them. `BUILD.json` and checksums identify each archive's source and final bytes.

macOS requires version 14 or later and supports Apple Silicon and Intel. Assets include universal DMG/ZIP, standalone CLI, Sparkle-signed update metadata and checksums. The application uses an ad-hoc signature and is not Apple-notarized. Permanent deletion cannot be undone through Shou. GitHub publication does not publish packages to npm.

简体中文：Shou v0.15.0 带来新的原生工作台，以及空间变化、诊断和应用版本的只读工具。

- 顶部任务导航、贯穿窗口的深浅色渐变、原创任务插画、全宽展开行与稳定选择底栏遵循最新共享设计；结果页优先展示操作和数据。
- 设置与 CLI 提供有界诊断报告，检查容量、访问和记录目录安全；省略个人路径及内容，不自动上传。
- 空间分析可比较同一目录保留的两次观察，核验身份、计量口径和覆盖，明确区分可比较变化、缺失、替换及不完整观察；历史结果不授予删除权限。
- 应用详情可由用户主动查询受支持的公开发布目录：macOS 通过 Homebrew Cask 查询六种稳定版应用，Windows 支持注册身份明确的 Visual Studio Code x64 稳定版。展示版本、观察时间及官方更新入口，不下载或安装更新。
- CLI 输出静态 Bash／Zsh 补全，Windows 另支持 PowerShell；不改 Shell 配置。macOS 在宽目录中优先发现固定产物路径和项目标记，保留活动保护及精确范围核验。

诊断、补全、空间比较及目录查询已有双端独立实现。Windows 为 **Windows 11 未签名便携预览**，提供 x64／ARM64 自包含应用与 CLI ZIP，清理、应用卸载和启动项变更的公开门禁继续关闭。ARM64 运行、完整界面／辅助功能、原生 MSI／任务验收、签名、安装及更新仍待完成，不能由交叉构建或 x64 启动检查替代。归档内 `BUILD.json` 和校验和记录确切源码与文件字节。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新元数据和校验和；应用使用 ad-hoc 签名，未经 Apple 公证。永久删除无法通过 Shou 撤销。GitHub 发布不会自动发布 npm 包。
