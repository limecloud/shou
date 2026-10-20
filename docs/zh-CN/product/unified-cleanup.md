# 统一日常清理

[English](../../product/unified-cleanup.md) | 简体中文

Shou 通过自动发现和统一清理为用户省时间。“项目清理”退出主导航，侧栏不再要求登记工作区。智能清理一次扫描应用缓存、开发工具缓存、项目产物及已启用的个人规则，通过一次具体范围确认完成清理。

## 使用体验

1. 打开智能清理，点击“开始扫描”；旁边菜单保留“扫描并释放空间”和“扫描位置”。
2. 自动发现固定缓存位置、常见开发目录和之前包含的文件夹，应用内置及已启用的个人规则，选中符合条件的结果。
3. 确认一次具体路径。默认永久删除，废纸篓为主动选择的替代方式；逐项展示结果与可恢复能力。

首页集中展示一个扫描主动作、当前磁盘容量与可选的 Agent 定制入口。智能清理和设置中的“扫描位置”为可选查看页；“包含其他文件夹”可以一次选择多个额外目录，并在以后自动扫描。高级规则预览仍可进入单个目录的详情页，并提供返回智能清理的操作。

大文件清理跨目录汇总符合条件的文件；空间分析负责目录浏览与矩形树图，两者均可直接选择内容清理。启动项、应用管理、清理规则与操作记录保留各自独立用途。

## 自动发现

`ProjectLocations` 只探测当前用户主目录下的一组常见项目集合：`Developer`、`Projects`、`Code`、`code`、`dev`、`src`、`repos`、`GitHub`，以及 `Documents` 下的 `Developer`、`Projects`、`Code`、`dev`、`GitHub`。这是目录元数据发现，不递归枚举整个主目录；Windows 发现等待经验证的平台适配器。

只为存在、本地且根身份有效的目录准备扫描。不存在的位置跳过；不可访问目录和符号链接明确报告覆盖问题；同一身份的别名去重。目录名称仅用于发现位置，不能作为删除证据：命中目标仍需规则、项目标记、活动检查、排除项和完整目标清单。

已有位置复用原逻辑引用、规则绑定及排除项。自动建议与已登记根重叠时跳过建议，避免引入范围更大的重叠根绕过既有策略。因此，显式登记的子项目可能限制其父集合目录的自动发现；需要时可包含其他不重叠的项目集合。

全部根准备完成后才捕获首个快照，确保同批快照配置摘要一致。`Workspace` 保留为内部身份与规则范围记录，并兼容现有 CLI；用户无需把它作为独立功能管理，也不必先进入登记页面。

### 已安装应用缓存

macOS 在精确的 `~/Library/Caches` 根扫描中，额外通过平台目录读取已安装应用。合法且归属唯一的 Bundle ID 生成只匹配该标识的相对规则；Mole 实测清单及其标识提示不参与执行。既有静态缓存模式优先，包括已禁用规则和仅覆盖后代的窄规则，通用发现不能扩大这些范围；动态规则也可通过绑定关闭。

只有独立完整、归当前用户且通过共享排除项、受保护内容与禁止跟随检查的缓存清单，才能进入推荐。系统／Apple 应用和当前应用受保护，运行中或状态未知时阻止清理。安装包可以由管理员拥有，因为这里只读核验安装包。缓存清理使用普通计划和回执，不卸载应用，也不选择偏好、支持数据或容器。

当前策略要求应用目录盘点完整，以确认唯一归属。盘点不完整或不可用时，静态规则继续扫描，`scanKnownLocations` 明确报告未纳入的通用覆盖；重复标识仅跳过这些通用 Owner，并报告歧义。`ScanSnapshot.status` 仍描述文件系统扫描是否完成；系统汇总遇到上述发现问题时为部分完成。任意自定义安装位置和其他账户不在目录覆盖范围内。

## 个人规则

现有 Agent 分析尚未覆盖的大目录，询问不明确的用途和重建方式，编写规则并预览禁用草稿。用户确认启用一次后，符合条件的命中项自动参与后续智能清理推荐；禁用草稿、预览快照、不完整及受阻目标继续排除。每次真实清理仍确认当前具体范围。

个人规则的启用及预览直接解析规则自身的根引用，不依赖用户另选扫描位置。Shou 仅提供 Skill 和 CLI，不接模型、不托管 Agent。

## 架构

```mermaid
flowchart LR
  Desktop[原生智能清理] --> Batch[共享批量扫描]
  CLI[system scan 指定 include-projects true] --> Batch
  Fixed[固定应用缓存] --> Roots[准备并复用根身份]
  Hints[常见开发目录] --> Roots
  Saved[记住的目录与策略] --> Roots
  Batch --> Roots
  Roots --> Scan[按规则只读扫描]
  Rules[内置及已启用个人规则] --> Scan
  Apps[实装包身份与运行状态] --> Generic[精确 Bundle ID 缓存规则]
  Generic --> Scan
  Scan --> Review[去重后的可清理推荐]
  Review --> Confirm[一次具体范围确认]
  Confirm --> Execute[共享永久或废纸篓执行]
  Execute --> History[逐项结果与历史]
```

## 流程

```mermaid
flowchart TD
  Open[打开智能清理] --> Scan[扫描全部包含位置]
  Scan --> Ownership{应用盘点完整？}
  Ownership -->|是| Exact[加入唯一标识缓存并保留静态窄范围]
  Ownership -->|否| Gap[报告通用覆盖缺口并保留静态规则]
  Exact --> Found
  Gap --> Found
  Found{有可清理目标？}
  Found -->|有| Review[展示已选目标与空间估计]
  Review --> Confirm{确认清理}
  Confirm -->|确认| Run[执行并报告实际结果]
  Confirm -->|取消| Review
  Found -->|仍有未覆盖大目录| Agent[通过现有 AI Agent 定制]
  Agent --> Draft[分析并预览禁用规则]
  Draft --> Enable[确认启用一次]
  Enable --> Scan
  Run --> Scan
```

## 时序

```mermaid
sequenceDiagram
  actor User as 用户
  participant UI as 智能清理
  participant Engine as ShouEngine
  participant FS as 平台适配器
  participant Apps as 应用盘点与运行状态
  participant Store as 本地记录
  User->>UI: 开始扫描，或扫描并释放空间
  UI->>Engine: scanKnownLocations(includeProjects: true)
  Engine->>FS: 探测常见目录并核验身份
  Engine->>Store: 复用策略并登记缺少的合格根
  loop 每个包含位置
    opt 精确的当前用户 Library/Caches 根
      Engine->>Apps: 读取实装身份与当前运行状态
      Apps-->>Engine: 唯一归属或明确发现问题
      Engine->>Engine: 保留静态范围并绑定精确动态规则
    end
    Engine->>FS: 按规则只读扫描
    Engine->>Store: 保存快照、配置摘要及可选实装证据
  end
  Engine-->>UI: 各位置证据与覆盖缺口
  UI->>UI: 汇总并推荐内置及已启用个人规则命中项
  UI-->>User: 类别三态选择、路径详情和固定底栏
  User->>UI: 调整选择并点击清理
  UI->>Engine: 准备具体选择的计划
  Engine->>Apps: 重新盘点并核验已选归属身份及运行状态
  UI-->>User: 一次路径及不可恢复确认
  User->>UI: 确认
  UI->>Engine: 按确认摘要执行
  Engine->>Apps: 重新盘点并核验已选归属身份
  loop 每个选中目标
    Engine->>Apps: 变更前重新读取具体应用与运行状态
    Engine->>FS: 重新核验并处理精确缓存目标，保留应用
  end
  Engine->>Store: 保存逐项结果
  Engine-->>UI: 完成结果与操作记录
```

## CLI 与验证

`shou system scan --include-projects true --json` 复用相同发现逻辑。CLI 为兼容保留默认 `false`；显式 `scan --workspace` 及 `workspaces` 命令继续服务 Agent 的范围绑定和高级自动化。

验证须覆盖新配置、发现不登记、重复扫描保留策略及摘要、显式重叠范围、符号链接、登记前取消、禁用草稿、启用个人规则自动推荐、隔离夹具实际清理／恢复和安装版原生界面。实际结果记入[验收记录](../engineering/acceptance-and-testing.md)。
