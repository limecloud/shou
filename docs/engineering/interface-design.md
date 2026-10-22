# Native interface design

English | [简体中文](../zh-CN/engineering/interface-design.md)

## Information hierarchy

Lead with the user's task: scan, inspect, select and clean. Keep navigation, page title and the primary action stable. Put exact paths, risks, coverage gaps and rebuild consequences beside the selection they affect. Technical module names and internal plan mechanics do not belong in ordinary user flows.

The main destinations are Smart Cleanup, Space Analysis, Large Files, Applications, Startup Items, Privacy, Personal Rules, History and Settings. Show only supported capabilities. Windows destinations are planned and require corresponding implementation and acceptance.

## Selection and results

Use a shared selection state for list, map and category views. Deduplicate parent/child selections and display allocated-byte estimates consistently. Preserve path origin and filename with a single middle ellipsis, exposing the full value to hover and accessibility.

The desktop defaults to permanent cleanup. Confirm the current exact selection, irreversible effect and separately consented personal data before execution. Optional Trash or Recycle Bin actions use explicit labels. Results distinguish completed, skipped, failed, cancelled and unknown outcomes; moving to Trash is not described as freed disk space.

## Native behavior

macOS uses SwiftUI/AppKit and Windows uses WinUI 3. Generate shared colors, typography, spacing, radii and text resources while using native keyboard, focus, dialogs, window and accessibility conventions. Validate light/dark, high contrast, reduced motion, long translations and DPI scaling. UI state may remain portable within a platform; UI framework types stay in the application layer.

## Validation

Use generated data to verify empty, loading, partial, ready, confirming, running, stopping, failed and completed states. Test source-page return, fresh rescanning, selection preservation, confirmation cancellation and accessible labels. Actual UI evidence is separate from state tests. See [workflows](../architecture/workflows-and-sequences.md) and [acceptance](acceptance-and-testing.md).
