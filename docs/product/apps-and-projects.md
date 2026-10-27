# Apps & Projects

English | [简体中文](../zh-CN/product/apps-and-projects.md)

Applications groups installed apps, Software Updates and Startup Items. Project outputs belong to Smart Cleanup, with Project Cleanup reached through Cleanup Options rather than an application tab. macOS includes application inventory/component review, project-output grouping, shared rule selection, single-app read-only update discovery and reviewed Homebrew/mise package upgrades. Windows has independent discovery and official WinGet upgrade source alongside navigation, marker-based project grouping and a shared scan/selection model. Unattended installation, Git remote-state investigation and whole-project removal are outside this implementation. Native acceptance and manual-review differences remain separately tracked; source availability does not establish complete platform parity.

Core deduplicates cleanup candidates and projects canonical built-in project templates plus personal rules with project evidence. Project recommendations, clearing and plans affect only that scope and preserve selected caches outside it. Package upgrades use an independent selection and authorization path.

Smart Cleanup, Projects, application components, Space Analysis and Large Files share one scope confirmation: review and select inline, then click the red Delete Permanently footer button to freeze that selection, validate and execute without another dialog. Project cleanup stays within its page scope; application personal-data consent and administrator authentication retain their separate requirements.

## Applications

Application bundles, verified related caches and user data expand within the same object row. Components retain their exact paths, byte estimates, ownership and current eligibility. Running applications, duplicate installations, shared components and unknown ownership continue to follow the independent [uninstall contract](application-uninstall.md).

Leftovers are reached from Applications; Startup Items uses its existing system adapter as a separate task in the same family. Visual integration does not turn cache rules into uninstall authority or startup registrations into cleanup permission.

Read-only update discovery lives in inline app details. Users explicitly query one app's public catalog version and open an official entry; unknown never means up to date. [Third-party updates and controlled upgrades](application-updates.md) owns source, network, version and identity boundaries, independently from this product's own updater.

## Packages and upgrades

Software Updates under Applications offers Homebrew and mise sources on macOS and the official WinGet source on Windows. Entering the page does not start a check. Users can search the provider's installed records, filter updates and select eligible targets. A package record alone does not establish ownership of an app path or project. Without a verified mapping, Shou does not merge it into app uninstall selection or count its contents again as cleanup capacity.

Upgrades require review and confirmation of a frozen exact selection, followed by source/identity/version rechecks and individual results. This is a separate installation task with its own action labels and short-lived, single-use authority. It cannot reuse the red permanent-delete action, cleanup consent or an earlier update attempt. Managers/installers can change dependencies and data; cancellation is not rollback, and unknown outcomes require checking installed versions before retrying.

mise upgrades are restricted to eligible user-global `latest` requests. Project versions, project configuration and project lockfiles remain outside the operation; the manager may update its global lockfile. Windows preserves the verified installation scope and exact official-catalog target, does not silently accept agreements or restart Windows, and awaits an already dispatched installer after stop. Detailed restrictions and verification boundaries are defined in the [update contract](application-updates.md#managed-package-upgrades).

## Developer projects

Local development, personal projects and cloned repositories use the same scan. Hosting origin does not determine eligibility. Core groups existing outputs/dependencies using manifest markers already observed by the scan. If a project root cannot be identified, the interface explicitly groups by scan location. This projection does not read source bodies, make Git network requests or assume that a remote copy makes local data recoverable.

Capacity is labeled Matched cleanup items and sums deduplicated candidates only, not the whole repository. Users select exact build-output, dependency and personal-rule paths. Source roots, manifests, lockfiles and protected data remain preserved. Global package caches remain independent Smart Cleanup tool categories; selecting one project never automatically selects the whole shared store.

On Windows, a personal-rule candidate enters Projects only beneath an observed regular, single-link project marker and within a scan root disjoint from canonical fixed-cache locations. Missing markers, cache scopes or unavailable catalog metadata keep it in Smart Cleanup only. Root references and directory names cannot replace this evidence. Both platforms group from each candidate’s own snapshot; Windows accounts for case-sensitive directories and similar prefixes.

Smart Cleanup and Projects share candidate identity and the selection set. Project actions prepare only selected project sources; Smart Cleanup clearly summarizes its entire selection. Search changes visibility only. Plan preparation retains parent/child deduplication and current-manifest checks.

## Rules and execution

Built-in and explicitly enabled personal rules share one source; do not duplicate project-specific rule definitions. Automatic recommendation is distinct from explicit manual review. Manual preparation measures complete current contents; an incomplete discovery manifest cannot directly authorize execution.

Cleanup defaults to permanent removal with exact paths and irreversible impact confirmed. Trash remains an explicitly named alternative and is not presented as equivalent freed space. This page provides no whole-project removal, automatic Git-change discard or worktree deletion shortcut. Such future capabilities require separate impact contracts for uncommitted, untracked and unpushed files, shared objects and local configuration.

## Verification

Domain fixtures cover project grouping, candidate identity, deduplicated capacity and separation from application caches. Existing cleanup checks retain permanent-removal/source-preservation, exclusions, changed-manifest rejection and no mutation before confirmation. Upgrade fixtures separately cover frozen targets, rechecks, single-use authorization and uncertain outcomes. Native UI, manager/installer behavior and packaged installation require separate evidence; pure .NET or generated-manager fixtures do not establish native WinGet acceptance. Native UI separately checks navigation, expansion, selection, capacity feedback, project-only review scope and cancellation. See [SYNC.md](../../SYNC.md).
