# Application-upgrade reference analysis

English | [简体中文](../zh-CN/engineering/application-upgrade-review.md)

On 2026-10-26, following the supplied screenshot, REA 6.7.0 inspected local `/Applications/Pulse.app` 0.1.29 and Computer Use observed its real interface without upgrading software. The purpose was to understand software-management tasks and implement them within Shou's native architecture and workspace. No target code, branding, icons or assets were copied. [Update discovery and controlled upgrades](../product/application-updates.md) owns product behavior.

## Evidence boundaries

The target bundle is `com.egoist.pulse`; its ARM64 executable SHA256 is `4ac148f0ceb7d57a55c85e6e7a4573883529c8ef8647fffbf9bcc807fda20d88`. Original REA records and real screenshots are in the review directory (local evidence: `output/reviews/application-upgrades-2026-10-26/`).

| Evidence | Supported conclusion | Not established |
| --- | --- | --- |
| `inspect_macho`, `ev_a5e7b2809336a2702659e54507785dade80e896cd124fae3fb45a2ffc9b2c081` | Observed ARM64 Mach-O structure, load commands, sections and imports | Upgrade business logic or deletion policy |
| Go metadata, `ev_4aea78c6894d26b71b00f74e14087e8b36f2094a50507452cf176e4c41e529ad` | Embedded claims of Go 1.27.1, module pulse, v0.1.29+dirty and dependencies | Compiler authenticity, original source or execution behavior |
| Artifact inventory, `ev_679254913c076c61bab504125d3e5742a1f08462b9c3d5aed4f595bbf54e98b8` | Package members/resources; inventory digest `c53d25848a749d3c12d7c025621599bf15292b99588db7119b74dc02d9e4bcc9` | Actual runtime use of every resource |
| Computer Use observations of Homebrew, mise, app details and menu | Visible entry points, version hierarchy, filtering and list organization | Commands, signatures, rollback or successful installation |

Deep `rea analyze` returned `provider_unavailable`: no supported decompilation engine was installed. REA's native UI helper also timed out during compilation and was not retried unchanged; Computer Use supplied real interface observations. Binary strings mentioning `apps.go`, `brew.go` and `mise.go` are navigation hints, not decompiled source. No REA/client configuration was changed or engine installed, and no upgrade was triggered in Pulse. mise was absent locally, so only its not-installed state was observed.

## Adopted tasks and design

| Observation | Shou implementation |
| --- | --- |
| App / Homebrew / mise source groups | Source switching inside Mac Applications; official WinGet on Windows with explicit platform differences |
| Installed and available versions together | Compare versions per row; unknown never means current; pinned/unsupported versions cannot authorize upgrades |
| Search, updates-only, check and update-all | Filters support selection; batch review lists frozen packages/target versions before confirmation |
| Source and upgrade entries in app details | Preserve read-only app catalog discovery; a Cask record cannot authorize mutation of a particular app copy without path-ownership evidence |
| Compact list and clear primary action | Keep Shou's top workspace, full-window gradient and shared artwork; checked results prioritize working space and a prominent upgrade footer |

The reference also displays size, last-opened and running-state fields; these observations do not make every field part of this upgrade scope. Shou adds no invented metrics, recovery or arbitrary-source installation. Upgrade progress and verification remain separate from cleanup receipts and freed-space totals. Builds, generated fixtures, real read-only inventories, actual installations and native Windows UI each require their own evidence. See [SYNC.md](../../SYNC.md) and the review report for actual outcomes.
