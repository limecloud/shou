# macOS native experience

English | [简体中文](../zh-CN/product/macos-experience.md)

Shou uses SwiftUI/AppKit with local deterministic services for cleanup and storage investigation. [Native interface design](../engineering/interface-design.md) owns current layout, typography and colors; this page owns journeys rather than a second sidebar/compact-size specification. Actual implementation and acceptance remain in [SYNC.md](../../SYNC.md).

## Start from a task

The unscanned start page introduces the task with original folder artwork, a mint/blue gradient and one scan action. Illustrated links open existing application/project, storage and rule pages. Scanning remains read-only; removal still requires review. The [design contract](../engineering/interface-design.md) owns composition and accessible decoration.

Smart Cleanup scans known application caches, developer tools and project locations without requiring users to write rules first. Additional folders can be included and remembered. Locations and exclusions remain inspectable. Permissions, truncation and cancellation must be explicit rather than represented as empty results or zero bytes.

Applications and Startup initially show illustrated introductions with explicit read-only scan buttons. Returning to a page with existing results retains those results. Space Analysis, Large Files, Projects and Privacy use the same composition with their own scope controls; Rules, Settings and populated History use compact illustrated headings. A continuous window-wide gradient runs behind navigation and content, while working surfaces retain readable contrast.

Top navigation groups Cleanup, Applications, Space Analysis and Monitor, with Toolbox, History and Settings utilities. Privacy belongs to Cleanup; rules and project cleanup are in Cleanup Options. Applications includes Software Updates and Startup Items. Space Analysis includes the directory view and Large Files. Toolbox selects AI Workbench or Developer Tools before loading a module. Native toolbars retain contextual actions. Navigation changes do not enable unsupported system capabilities.

## Scan, inspect and select

Smart Cleanup presents categories first, then rules/software and exact paths. Recommendations require current ordinary-rule eligibility and recommendation coverage. Explicit manual review retains reasons/impact and measures complete current contents before confirmation. Core still rejects protected locations, exclusions and stale evidence.

Focus inspects an item; checkboxes change scope. Search, sort, expansion and navigation never expand permission. Mixed group selection follows selectable objects, with actual selected count and allocated-byte estimate in the footer. Snapshots, compression, clones, hard links and open files may affect observed volume availability.

Projects reuse the same candidates and rules, grouping by observed roots or explicitly by scan location when unknown. Source and global shared package stores are not automatically included. See [Apps & Projects](apps-and-projects.md).

Space Analysis uses independent volume/folder evidence. Map and list share navigation, deduplicated selection and exact removal scope. A click focuses; a double-click enters. Unreadable data is not zero bytes. Removing an index requires a new scan. See [Space Analysis](space-analysis.md).

## Review, execute and inspect results

Everyday cleanup defaults to permanent deletion with an explicit main action. Trash has a separately named alternative. Confirmation binds this exact scope and action, never long-lived permission. Manual review explains complete-directory impact and the absence of a rebuild guarantee. Uninstall, privacy and direct storage removal retain their own contracts.

Execution shows real stages, paths, processed counts and stopping status. A stop waits for the current system operation's real outcome and does not automatically roll back or replay. Results independently report completed, skipped, failed, cancelled and unknown outcomes, preserving item-level reasons in history. Trash is not reported as freed space, and permanently removed items have no recovery action.

During cleanup, restoration or permanent removal, normal close/quit defaults to keeping the application open. A requested stop waits for safe boundaries and receipts; errors or unknown outcomes keep the window available. Idle close/quit follows native behavior. See [operation progress](operation-progress.md) and [cleanup safety](../security/cleanup-safety.md).

## Rules and optional AI

Rules combines built-in/personal definitions, switches, versions and exclusions. An edit creates a disabled version rather than silently replacing the active version. Preview, explicit enablement and rescanning remain separate. Configuration changes invalidate old evidence, selections and confirmation. Advanced editing preserves JSON that cannot map losslessly to a wizard.

AI optionally explains occupancy and proposes rule drafts; it does not execute deletion. Distinguish external-tool handoff from an embedded provider connection, and preserve accurate disabled/cancelled/timeout/offline/no-suggestion states. See [AI interactions](embedded-ai.md), [rule specification](../rules/rule-specification.md) and [cleanup/exclusions](unified-cleanup.md).

## Native behavior and accessibility

Retain native folder selection, menus, focus and keyboard conventions: Settings uses `⌘,`, scanning supports `⌘R`, and destructive actions have no easy single-key shortcut. Icons have localized labels. Full paths remain copyable and available when truncated. Changing language never changes identity, matching or execution.

Reduced motion respects both application and system settings. Unknown totals show actual counts instead of invented percentages. Pair risks with text/icons and retain a list alternative to maps. Verify both appearances, minimum window, English/Chinese and long paths. VoiceOver speech, full keyboard journeys and installed native behavior require separate evidence.
