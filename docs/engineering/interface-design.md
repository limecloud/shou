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

## Shared design resources

Edit only `assets/design/tokens.json` for extracted design values. Run `python3 "scripts/generate-windows-resources.py"`, then add `--check` to verify reproducibility. The command generates `apps/windows/Generated/Design.xaml` and `apps/macos/Sources/ShouDesign.generated.swift`; neither file is edited manually. The manifest records canonical source and generator digests, and the Swift header records its source digest.

Schema version 1 supports named sRGB colors (`#AARRGGBB`), numbers, uniform radii and uniform padding. Names must start with `Shou` followed by an uppercase letter and contain only ASCII letters/digits. Names are unique across groups. Numeric values must be finite, nonnegative and at most 4096; booleans, strings, duplicate JSON keys and unsupported groups are rejected. Generated Swift colors retain all four channels; numeric values use `CGFloat`. Design resources do not enter Core or CLI dependencies.

Extracted values include primary-action dimensions, cleanup artwork dimensions, path width and motion period. SwiftUI uses the accent, settings spacing/card radius, scan-location sheet padding and cleanup motion values; WinUI pages use item/section/page spacing and page padding. macOS scan and cleanup progress share the same flat file-convergence animation; losing window focus does not pause it. Cleanup stays in the main page with a fixed title, converging-file artwork, measured percentage, a thin progress bar, one middle-truncated path and direct Stop; detailed item counts and item lists are omitted. Windows cleanup motion, accent/radius integration and other visual values remain pending. Fluent control colors, platform typography, focus and high-contrast behavior remain native. Compilation and resource checks do not prove layout, DPI or accessibility acceptance.

## Validation

Use generated data to verify empty, loading, partial, ready, confirming, running, stopping, failed and completed states. Test source-page return, fresh rescanning, selection preservation, confirmation cancellation and accessible labels. Actual UI evidence is separate from state tests. See [workflows](../architecture/workflows-and-sequences.md) and [acceptance](acceptance-and-testing.md).
