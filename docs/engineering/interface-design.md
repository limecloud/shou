# Native interface design

English | [简体中文](../zh-CN/engineering/interface-design.md)

This is Shou's current interface source of truth. The workspace design introduced on 2026-10-25 replaces the sidebar and compact-type baseline. Historical screenshots and parity records do not constrain this redesign. Product, safety and platform contracts retain their own authority.

## Direction

Build an open, legible workspace that users can inspect. Adapt the hierarchy, full-width lists, inline details and stable action areas shown in the reference demonstration, using Shou's own cool neutral surfaces and teal accent. Retain Shou branding and native behavior; do not copy logos, planetary artwork or individual screens pixel for pixel. See the [video review](workspace-design-review.md) for evidence.

Give names, paths and sizes the available width instead of persistent navigation columns and competing summaries. Establish a clear hierarchy between page titles, object rows and details. Enlarging every control or adding decorative cards does not create a spacious design. Use panels only for meaningful task or selection boundaries.

## Navigation and composition

Primary navigation sits at the top: Cleanup, Apps & Projects, Space Analysis and Rules. History and Settings have stable controls on the right. Secondary navigation belongs below it:

| Primary destination | Tasks |
| --- | --- |
| Cleanup | Smart Cleanup and Privacy |
| Apps & Projects | Applications, Developer Projects and Startup Items; leftovers are reached from Applications |
| Space Analysis | Space Analysis and Large Files |
| Rules | Built-in/personal rules, scan locations and exclusions |

The native title bar retains window controls and contextual tools. Introductions explain purpose; results start directly with contextual tools and data; progress and completion have their own focused composition. Results fill the remaining height. Batch selection actions remain at the bottom. Do not add duplicate version, capacity or permanently empty status bars. Operation status remains accessible.

Current shared tokens set the initial window to 1440 × 875 pt with a 960 × 680 pt minimum; the system still restores saved window sizes. Check English, long paths and the minimum window. Reflow filters when necessary instead of shrinking essential text.

## Cleanup workspace

Before scanning, the default page uses a horizontal hero: a two-line title, purpose, gradient scan button and review-before-removal note on the left; an original translucent folder, layered documents and floating app tiles on the right. `WorkspaceBackdrop` owns a continuous mint-to-ice-blue background across the entire window: primary/secondary navigation, whitespace and content. The gradient is not confined to an illustration or rounded hero panel. Dark appearance has a separate low-luminance palette; increased contrast removes decorative glows. Three illustrated destinations below open existing Apps & Projects, Space Analysis and Rules pages. Optional AI actions occupy a secondary utility row.

[WorkspaceIllustration.swift](../../apps/macos/Sources/WorkspaceIllustration.swift) owns editable artwork; [CleanupWelcomeView.swift](../../apps/macos/Sources/CleanupWelcomeView.swift) composes the page. Native vectors and gradients scale without network images or external assets. Shared tokens own colors and extracted layout values; drawing coordinates belong to the artwork source. Decorative space blocks convey neither measured capacity nor cleanup eligibility and are hidden from accessibility. There is no perpetual home animation; hover displacement respects reduced motion. The page scrolls vertically when needed rather than clipping its scan action.

Other destinations use distinct compositions from [WorkspacePageArtwork.swift](../../apps/macos/Sources/WorkspacePageArtwork.swift) and a shared `WorkspaceStartPage`. Applications and Startup initially explain their task and offer a read-only check; once started, actual progress and results replace the introduction. Existing results survive navigation. Space Analysis and Large Files retain scope pickers, Projects reuses the common scan, and Privacy retains time range, permanent-removal impact and supported-source limitations. Rules, Settings and populated History show content immediately with compact illustrated headings. Empty history and filtered results have corresponding illustrations. Decoration never grants confirmation authority.

| Page | Artwork |
| --- | --- |
| Applications | Layered app panels and icon grid |
| Developer Projects | Terminal, code and build package |
| Space Analysis | Space blocks and drive |
| Large Files | Documents, media and magnifier |
| Privacy | Browser document, shield and lock |
| Startup | Power tile and launch arrow |
| Rules / Settings | Layered adjustment panels with check / gear |
| History | Receipt and clock |

Prioritize practical working space: populated Space Analysis, Large Files, Applications, Startup and Privacy omit large artwork and duplicate page titles. Projects retains only a compact introduction. Give remaining height to filters, lists/maps and fixed actions, including at minimum window size.

Results start with categories, location counts and allocated-byte estimates. Full-width categories expand to rules/software, then exact paths. Search uses the same objects. Mixed-state selection reflects the current selection at every level; focus and expansion never select targets.

The footer shows selected count, selected capacity and one explicit permanent-cleanup action. Trash remains a secondary choice. Manual-review items may be selected explicitly but never become automatic recommendations. Preparation measures the complete current directory and explains its full impact. Core retains protected-location, exclusion, owner and current-manifest decisions.

Space Analysis and Large Files retain their existing [storage contract](../product/space-analysis.md). Map area represents occupancy, not blanket cleanup eligibility.

## Applications and projects

Applications use spacious rows with icon, name/version, status, size and last use. Inline details show related components and exact paths. Personal-data consent stays beside component selection. Unknown ownership and shared data remain protected or unavailable. Uninstall retains its independent confirmation contract.

Update checks live in inline app details, explain the single-app network source and start only when clicked. Show versions, observation time and unknown causes; users explicitly open the official entry. Reuse the existing list/disclosure without another top-level update navigation item. [Update discovery](../product/application-updates.md) owns source and version limits.

Developer Projects groups build outputs and dependencies using observed project markers. Unidentified projects explicitly fall back to the scan location. Displayed capacity covers matched cleanup items, not the entire source repository. Smart Cleanup and Projects share candidate identity, rules and selection; project actions prepare only the project scope. See [Apps & Projects](../product/apps-and-projects.md).

## Visual resources

Maintain extracted design values only in `assets/design/tokens.json`. Mac introductions use 72 pt primary navigation; results, scanning and functional lists use a compact 48 pt navigation. Windows currently uses 48 pt navigation throughout. Rules, History and Settings use 22 pt headings; other results omit duplicate page titles, 14 pt object text, 40 pt icons and 28 pt content insets. Row spacing and summary figures also come from generated resources. Keep paths, details and status readable instead of restoring the old 10 pt essential text density.

Check actual light/dark appearance, accent contrast, selection and focus. Pair state colors with text or icons. Map palettes encode data and do not decorate whole pages. Native high contrast, reduced motion, keyboard and accessibility take precedence over decoration.

Run `python3 scripts/generate-windows-resources.py` and `--check` to maintain Windows XAML and `ShouDesign.generated.swift`; never edit generated copies. On Mac, `python3 scripts/workspace_artwork.py` exports ten transparent PNGs and a source/output digest manifest. The Windows generator copies them into `Generated/Illustrations`. After source or token changes, export before generating; both scripts support `--check`. Mac retains the original vectors. The String Catalog owns text. The generator and its tests own schema fields, digests and rejection rules.

## Implementation and verification

macOS has been built and installed over the local application; [SYNC.md](../../SYNC.md) records actual checks. Windows source now implements task-family navigation, the continuous gradient, shared-artwork introductions and full-width cleanup results. Project selection is limited by canonical categories; marker-based project grouping and Mac manual-review parity remain pending. On 2026-10-26, Windows 11 x64 cloud acceptance built real WinUI XAML and used Computer Use to inspect introductions, read-only scans, expansion, selection, a small window and live light/dark changes. Double/GridLength resource type errors in Settings and privacy row templates were fixed; code-created controls now retain dynamic theme references. See [Windows test results](windows-testing.md#2026-10-26-windows-11-cloud-acceptance) for screenshots and failure receipts. Public mutations, complete desktop E2E, complete ARM64 UI, signed installation and per-page macOS parity remain unaccepted.

Use generated data for empty, loading, partial, ready, confirming, executing, stopping, failed and completed states. Verify primary/secondary navigation, expansion versus selection, filtered selection, footer estimates, confirmation cancellation, the minimum window and both appearances. Delete only generated fixtures; personal data is limited to read-only inspection and cancellation. Builds, state tests and resources do not replace actual UI or signed-installation evidence.
