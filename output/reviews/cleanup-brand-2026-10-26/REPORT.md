# Shou 界面与品牌验收 · 2026-10-26

已覆盖 `/Applications/Shou.app` 0.16.0 开发构建；154 个应用文件核验通过，867 条既有记录保留。新版本保留共享工作区内独立的系统监控工作。

默认窗口 token 为 1280 × 800，首页同时依据宽度和高度调整插画、间距与入口卡片，不锁定比例。已检查大窗口、小窗口、浅色和深色：首页扫描按钮、三个入口与底部辅助入口均可见。图片修正采用透明轮廓平滑和高质量缩放，保留 RGB 材质细节。

## 最终安装版截图

以下均通过 Computer Use 操作安装后的原生应用取得。原始截图是 JPEG，保留为 `.jpg`；另转为 PNG 便于归档。实际像素尺寸与摘要见 [verification.json](verification.json)，不据此推断逻辑 DPI。

| 页面／状态 | 截图 |
| --- | --- |
| 完整首页 | [浅色首页](01-home-light.png) |
| 紧凑窗口首页 | [完整入口](02-home-compact-light.png) |
| 约 960 像素宽首页 | [扫描、三个入口、辅助链接](03-home-minimum-light.png) |
| 应用 | [初始页](04-applications-light.png) |
| 开发项目 | [初始页](05-projects-light.png) |
| 启动项 | [初始页](06-startup-light.png) |
| 空间分析 | [初始页与位置选择](07-space-light.png) |
| 大文件 | [初始页与位置选择](08-large-files-light.png) |
| 隐私 | [初始页、时间范围与影响说明](10-privacy-light.png) |
| 规则 | [紧凑插画标题与规则列表](11-rules-light.png) |
| 操作记录 | [已有记录与紧凑插画标题](12-history-light.png) |
| 设置 | [关于图标与版本](13-settings-about-light.png) |
| 深色设置 | [图标与深色表面](14-settings-dark.png) |
| 深色首页 | [透明边缘与完整首屏](15-home-dark.png) |

测试结束已恢复原来的“跟随系统”外观选项。规则／历史／设置展示真实内容；本轮仅检查页面和品牌展示，没有执行新的扫描或真实个人数据删除。

## 共享插画与官网素材

十个主题使用同一品牌母版作为 GPT Image 参考，经已安装的 imagegen fallback CLI edit 生成；请求 `gpt-image-2`，完整提示词与接口响应／母版摘要在[插画记录](../../../assets/design/illustrations/README.md)。原始响应来自用户指定接口，上游模型身份未独立核验。网站资源从批准图片离线导出，没有新增网站功能。

- [浅色背景整套预览](illustrations-light.png)
- [深色背景整套预览](illustrations-dark.png)
- [网站 Logo、字标及图标预览](website-brand-preview.png)
- [官网素材包说明](../../../assets/brand/web/README.md)：透明 PNG／WebP 标识、浅深横版字标、favicon、Apple Touch Icon、192／512 图标、十张 WebP 插画，共 22 个图片输出。
- [品牌生成方式与最终提示词](../../../assets/brand/generation.md)

构建、官网导出和运行时均不请求模型服务，不需要接口密钥。母版、提示词、资源 token 和生成记录为事实源；Mac／Windows 复制同一 PNG，避免两端单独绘制。

## 验证与边界

最终 Mac 桌面／CLI 构建、签名完整性、包内所有插画、ICNS、透明标识与候选包字节检查通过，见 [macos-build.log](macos-build.log) 和 [installation.json](installation.json)。插画摘要、Windows／Swift 生成资源、官网素材、文案、文档和 `git diff --check` 均通过，见 [verification.json](verification.json)。

Windows 已同步默认尺寸、按可用高度收紧初始布局、横向入口、十张 PNG、品牌图标、红色操作按钮及行内确认源码；本轮仅核验共享资源和 XAML XML 语法，没有新做原生 WinUI 编译、DPI 或真实 Windows 界面验收。公开变更门禁继续关闭。此前云电脑验收对应其当时 payload，不能代替本轮新增布局的原生验收。

此前清理交互验证通过 306/306 Swift 领域／生成夹具检查；完整常规脚本末项 Node 夹具被宿主 `build_process_running` 阻断，不能记为全套通过。可移植 .NET 通过 1,245 项、跳过 88 项原生／专项，并通过 192 项 CLI 合同。日志为 [earlier-macos-tests.log](earlier-macos-tests.log) 与 [earlier-windows-tests.log](earlier-windows-tests.log)；它们早于最后的图片轮廓和首页布局修改，不能充当最终 UI 验收。

## 较早的生成夹具清理证据

以下用于证明行内选择与红色永久删除交互，截图中的插画属于当时版本，不是最终插画验收图：

- [智能清理选择](fixture-01-smart-selection.png) → [生成夹具清理完成](fixture-03-smart-completion.png)
- [应用组件选择](fixture-04-app-selection.png) → [生成应用清理完成](fixture-05-app-completion.png)
- [开发项目选择](fixture-07-final-project-selection.png)、[紧凑窗口底栏](fixture-08-final-project-compact.png)：后续项目夹具仅选择，未执行删除。

删除回归只使用本次生成的临时夹具。最终视觉检查没有把真实用户目录作为删除样本。
