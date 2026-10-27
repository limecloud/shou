# Native interface design

English | [简体中文](../zh-CN/engineering/interface-design.md)

This is Shou's current interface source of truth. The workspace design introduced on 2026-10-25 replaces the sidebar and compact-type baseline. Historical screenshots and parity records do not constrain this redesign. Product, safety and platform contracts retain their own authority.

## Direction

Build an open, legible workspace that users can inspect. Adapt the hierarchy, full-width lists, inline details and stable action areas shown in the reference demonstration, using Shou's own cool neutral surfaces and teal accent. Retain Shou branding and native behavior; do not copy logos, planetary artwork or individual screens pixel for pixel. See the [video review](workspace-design-review.md) for evidence.

Give names, paths and sizes the available width instead of persistent navigation columns and competing summaries. Establish a clear hierarchy between page titles, object rows and details. Enlarging every control or adding decorative cards does not create a spacious design. Use panels only for meaningful task or selection boundaries.

## Navigation and composition

Primary navigation sits at the top: Cleanup, Apps & Projects, Tools, Space Analysis, Monitor and Rules. History and Settings have stable controls on the right. Secondary navigation belongs below it:

| Primary destination | Tasks |
| --- | --- |
| Cleanup | Smart Cleanup and Privacy |
| Apps & Projects | Applications, Developer Projects and Startup Items; leftovers are reached from Applications |
| Tools | [Developer Tools](../product/developer-tools.md) and [AI Workbench](../product/ai-workbench.md), independent of project cleanup |
| Space Analysis | Space Analysis and Large Files |
| Rules | Built-in/personal rules, scan locations and exclusions |

Show the application name once in the native title bar; do not repeat the logo and brand in the content header. Align primary and secondary navigation to the content’s left inset, with History and Settings on the right. The native title bar retains window controls and contextual tools. Introductions explain purpose; results start directly with contextual tools and data; progress and completion have their own focused composition. Results fill the remaining height. Batch selection actions remain at the bottom. Do not add duplicate version, capacity or permanently empty status bars. Operation status remains accessible.

Current shared tokens set a 1280 × 800 logical-unit initial window (16:10) with a 960 × 680 pt Mac minimum; the system still restores saved window sizes. Windows fits its initial size to the available work area and DPI. Both platforms adapt to available page height rather than require a fixed aspect ratio. Check English, long paths and the minimum window. Reflow filters when necessary instead of shrinking essential text.

## Cleanup workspace

When the home page has less than 620 logical units of height or 1100 of width, reduce headline spacing, artwork size and outer insets. Three destinations use compact horizontal text-and-art cards. Keep the scan action, destinations and utility links visible together; scrolling remains available for exceptionally small windows or long text. Smooth illustration alpha contours before rebuilding antialiased edges without blurring RGB material detail; Mac uses high-quality interpolation.

Before scanning, the default page uses a horizontal hero: a two-line title, purpose, gradient scan button and review-before-removal note on the left; the original smiling jade storage-box mascot on the right, with transparent edges blending into the workspace. `WorkspaceBackdrop` owns a continuous mint-to-ice-blue background across the entire window: primary/secondary navigation, whitespace and content. The gradient is not confined to an illustration or rounded hero panel. Dark appearance has a separate low-luminance palette; increased contrast removes decorative glows. Three illustrated destinations below open existing Apps & Projects, Space Analysis and Rules pages. Optional AI actions occupy a secondary utility row.

The home mascot comes from the [shared brand raster](../../assets/brand/README.md); [CleanupWelcomeView.swift](../../apps/macos/Sources/CleanupWelcomeView.swift) composes the page. Settings → About Shou displays the matching app icon beside the version. Cleanup, Applications, Projects, Space, Large Files, Privacy, Startup, Rules, History and Settings use a coordinated GPT Image family. [Shared illustrations](../../assets/design/illustrations/README.md) retain masters, prompts and generation records. Mac `WorkspaceIllustration` and `WorkspacePageArtwork` load packaged PNGs; Windows uses identical bytes. Every asset ships inside the app, with no runtime image requests. Shared tokens own interface colors and extracted layout values. Illustrations retain jade, ivory, coral accents, soft 3D materials and the brand master as their reference. Decorative space blocks convey neither measured capacity nor cleanup eligibility and are hidden from accessibility. There is no perpetual home animation; hover displacement respects reduced motion. The page scrolls vertically when needed rather than clipping its scan action.

Windows landing coverage issues use a short status and a details link. Full paths appear on demand in a bounded scrollable flyout, using the same interaction as results. With no usable locations, Scan Locations opens the existing configuration page. Long diagnostics must not displace the scan action or lower task destinations.

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

The footer shows selected count, selected capacity and a prominent large red Delete Permanently button. Smart Cleanup, Projects, Space Analysis, Large Files and application-component cleanup share one flow: review and select inline, then click once to confirm the frozen scope, validate and execute without a second dialog. Trash remains a secondary menu action. Whole-directory impact, rebuilding costs and personal-data consent stay beside selection; manual items are never recommended. Preparation is cancellable. Core retains protected-location, exclusion, owner and current-manifest checks. Windows system uninstall reviews exact installation identity and installer-data consent inline; the red uninstall button confirms the current operation. Its public execution gate remains closed.

Space Analysis and Large Files retain their existing [storage contract](../product/space-analysis.md). Map area represents occupancy, not blanket cleanup eligibility.

## Applications and projects

Applications use spacious rows with icon, name/version, status, size and last use. Inline details show related components and exact paths. Personal-data consent stays beside component selection. Unknown ownership and shared data remain protected or unavailable. Uninstall retains independent component, personal-data and system-identity checks, with one inline action confirming the current selection and no duplicate dialog.

Update checks live in inline app details, explain the single-app network source and start only when clicked. Show versions, observation time and unknown causes; users explicitly open the official entry. Reuse the existing list/disclosure without another top-level update navigation item. [Update discovery and controlled upgrades](../product/application-updates.md) owns source and version limits.

macOS Applications uses Applications / Homebrew / mise source tabs. Package-manager start pages keep the shared artwork; checked results use the full-width list. Names, installed/target versions, package kind, eligibility, search, updates-only filtering and the stable action footer remain visible. Individual or batch upgrades enter an inline frozen-selection review, then the primary Confirm Upgrade action executes once. Keep it distinct from red permanent deletion without another confirmation. Results distinguish verified, not started, blocked before dispatch and uncertain outcomes; another check is required before retrying.

Windows opens a native WinGet window from Application Updates with version comparison, filtering and selection. Review freezes and displays the complete selected scope, including packages hidden by a filter; search and selection are disabled until Cancel returns to selection. The blue Confirm Upgrade action executes the plan once without another dialog. Execution blocks exit; Stop waits for the current installer result. Platform sources differ, so inactive Homebrew/mise placeholders do not establish parity. See [application-upgrade design analysis](application-upgrade-review.md) for reference evidence and adoption boundaries.

Shou self-updates live in Settings → About Shou without another top-level navigation item. Native update windows emphasize the brand icon, version difference, scrollable notes and primary update action, with checking, up-to-date, incompatible and connection-failure feedback. macOS shows the last check and automatic check/install options; Windows portable builds explain manual replacement, and closing the dialog promises no background reminder. [Desktop update behavior](releasing.md#desktop-update-behavior) owns installation and signature boundaries.

Developer Projects groups build outputs and dependencies using observed project markers. Unidentified projects explicitly fall back to the scan location. Displayed capacity covers matched cleanup items, not the entire source repository. Smart Cleanup and Projects share candidate identity, rules and selection; project actions prepare only the project scope. See [Apps & Projects](../product/apps-and-projects.md).

## Visual resources

The app mark is an original smiling jade storage box, with an ivory lid and coral tab as recognizable details. [Brand resources](../../assets/brand/README.md) retain the raster master, generation record and prompt. Generate Mac ICNS and Windows ICO from that same master and inspect 16/32/64 px readability. Home and Settings About display these shared brand images. Content navigation does not repeat the brand block. Page artwork shares character proportions, materials, lighting and transparent backgrounds. The future [website asset kit](../../assets/brand/web/README.md) uses the same sources.

Maintain extracted design values only in `assets/design/tokens.json`. Mac introductions use 72 pt primary navigation; results, scanning and functional lists use a compact 48 pt navigation. Windows currently uses 48 pt navigation throughout. Rules, History and Settings use 22 pt headings; other results omit duplicate page titles, 14 pt object text, 40 pt icons and 28 pt content insets. Row spacing and summary figures also come from generated resources. Keep paths, details and status readable instead of restoring the old 10 pt essential text density.

Check actual light/dark appearance, accent contrast, selection and focus. Pair state colors with text or icons. Map palettes encode data and do not decorate whole pages. Native high contrast, reduced motion, keyboard and accessibility take precedence over decoration.

Run `python3 scripts/generate-windows-resources.py` and `--check` to maintain Windows XAML and `ShouDesign.generated.swift`; never edit generated copies. On Mac, `python3 scripts/workspace_artwork.py` exports ten transparent PNGs offline from approved raster masters and records source/output digests. Mac packages and verifies every PNG; the Windows generator copies identical bytes into `Generated/Illustrations`. Explicit `--import-generated` imports new model outputs and retains prompts and preparation records; ordinary export never accesses the network. After artwork source changes, export before generating; both scripts support `--check`. Export and verify website assets with `scripts/export-web-brand.py`. The String Catalog owns text. The generator and its tests own schema fields, digests and rejection rules.

## Implementation and verification

macOS has been built and installed over the local application; [SYNC.md](../../SYNC.md) records actual checks. Windows source now implements task-family navigation, the continuous gradient, shared-artwork introductions and full-width cleanup results. Projects now has Core marker-based grouping, exact paths, deduplicated capacity, tri-state selection and the same scan/selection model as Smart Cleanup. Recommendations, clearing and plans stay within project scope; personal rules require a project marker and a scope disjoint from fixed shared-cache roots. Pagination distinguishes displayed and total matched locations. Native interaction acceptance for this new project UI and Mac manual-review parity remain pending. On 2026-10-26, Windows 11 x64 cloud acceptance built real WinUI XAML and used Computer Use to inspect introductions, read-only scans, expansion, selection, a small window and live light/dark changes. Double/GridLength resource type errors in Settings and privacy row templates were fixed; code-created controls now retain dynamic theme references. See [Windows test results](windows-testing.md#2026-10-26-windows-11-cloud-acceptance) for screenshots and failure receipts. Public mutations, complete desktop E2E, complete ARM64 UI, signed installation and per-page macOS parity remain unaccepted.

Use generated data for empty, loading, partial, ready, confirming, executing, stopping, failed and completed states. Verify primary/secondary navigation, expansion versus selection, filtered selection, footer estimates, confirmation cancellation, the minimum window and both appearances. Delete only generated fixtures; personal data is limited to read-only inspection and cancellation. Builds, state tests and resources do not replace actual UI or signed-installation evidence.

## System monitor

Monitoring uses two rows of eight panels: resource status, CPU, GPU, memory; battery, disk, network, thermals and fans. Trends sit inside their panels above the full-width process list with search/sort; per-core CPU and memory details expand progressively. Retain the full-window gradient, readable translucent surfaces, shared radii and body text, with scrolling at 960 × 680. Explain the load-status basis without an unsupported health score; unknown sensors stay missing. Status bar, Dock, tray and supported taskbar entries share sampling state and strings, with open/pause/disable commands and normal native exit. The [monitoring contract](../product/system-monitor.md) owns metrics, permissions and verification.

## Interface style baseline

Applies to every native page in this repository, including the added Developer Tools, AI Workbench, MySQL administration and update interfaces. Existing pages are included.

1. Do not use middle dots as copy separators. Prefer aligned columns for source/version/state, colons for label/value pairs, and commas or line breaks for sequences. Preserve original filenames, code and log contents.
2. Remove repeated headings, standing tutorials and explanatory clutter. Keep relevant state, scope, limitations, failures and consequences. Put consequences in the existing review step without repeated confirmation.
3. Write concise, accurate copy for the current audience. Use clear action verbs; avoid casual wording, invented terms and unnecessary implementation details.
4. Use [Radix UI Colors](https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale) for all custom interface colors. Shared tokens own editable design values; the [scale mapping](../../assets/design/radix-colors.json) records the official revision and provenance, checked offline by the generator. Slate is neutral, Teal is the accent, and Green/Amber/Red express success/attention/danger. Steps 1–2 are backgrounds, 3–5 interactive surfaces, 6–8 borders/focus, 9–10 solid actions, 11 supporting/semantic text and 12 primary text. Accent text uses Teal 11; check text contrast on solid buttons. System-owned windows and high-contrast mode retain native accessibility semantics. Brand bitmaps are distinct from interface colors.
5. Align text baselines, optical icon centers and table columns. Nested radii follow the outer radius minus padding; inner radii never exceed outer radii. Use square inner regions when padding consumes the radius and avoid nested cards.
6. Custom borders and separators use shared `ShouHairlineWidth = 0.5` logical units: pt on macOS and DIP on WinUI. Native focus rings and data chart strokes retain their functional dimensions.
7. Avoid decorative animation. Necessary transitions use ease-out/250 ms and respect Reduce Motion. Avoid simultaneous loading indicators and looping decoration.
8. Prefer three text sizes per page, never more than four, with a minimum of 12. Working pages use 12/14/22: 14 body, 12 paths/supporting state and 22 main headings. Use weight, semantic color and spacing for remaining hierarchy. Review icon sizes separately.
9. Reduce extra decisions. Put necessary choices in existing source/object selection or review steps. Preserve exact scope and single confirmation contracts without redundant dialogs or removing required consequences.
10. Use radii and shadows to establish useful control boundaries. Prefer whitespace and 0.5 separators for lists; no decorative colored card edge. Preserve capsule switches and usable hit targets.
11. Remove Eyebrows/Overlines that repeat headings. Keep one only when it adds classification or context; use typography, weight and whitespace for hierarchy.

The repository skill references this section; do not install global rules. Native acceptance covers both appearances, minimum window size, long paths, list selection and existing reviews. Synchronized Windows source/resources do not establish WinUI acceptance.

## Tool rail and source table

Developer Tools and AI Workbench share a compact toolbar, 232 pt independently scrolling category rail and persistent source/version/path table. My Workspace is the default; Add Tools incorporates installed state. Direct capsule switches control only a unique verified source; multiple versions are explicit, and unknown/unsupported/gated state is labeled. Configuration & Extensions retains the same shell. Widths come from canonical tokens. Verify the minimum viewport without letting oversized artwork displace working rows. See [tool management](../product/developer-tools.md).

Keep the detail title, task tabs and source filters above the scrolling body. Log tasks fill the remaining height and scroll only their text, with path selection at the top and exact-scope review, feedback and clearing actions at the bottom. MySQL error and slow-query logs reuse the same text component. An expanded review shrinks the log viewport while keeping confirm and cancel visible. Catalog rows use thin dividers and aligned identity text/capsule switches, omit empty source lines, and center empty-workspace artwork, heading and action on one axis. Show one loading status per discovery task.
