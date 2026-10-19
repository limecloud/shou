# CLI and structured operation contract

English | [简体中文](../zh-CN/ai/agent-and-cli-contract.md)

Status: API `1.0` development contract. Commands have a source implementation. Discover the current binary's actual capabilities and follow the [development guide](../engineering/development.md); release acceptance is pending.

## 1. Independent entry points

Desktop and CLI share workspaces, rules, scans, plans, protection, and history. The CLI completes cleanup without a desktop process.

Existing coding agents may call the public CLI under their own authorization policies. Shou integrates no models and develops, starts, or hosts no agents. Persistent business capabilities must be discoverable rather than hidden exclusively in GUI actions; temporary view state is exempt.

## 2. Global behavior

- Command: `shou`, future Windows `shou.exe`.
- `--help` explains usage; `capabilities --json` reports actual commands, input definitions, limits, and side effects.
- `--locale` changes human text according to [internationalization](../product/internationalization.md), never machine semantics.
- `--json` emits exactly one UTF-8 envelope on stdout; progress and prompts use stderr or a controlling terminal.
- Escape untrusted terminal/path content. Machine values use integer bytes, UTC ISO 8601 timestamps, stable English identifiers, and explicit completeness.
- Page large results with stable snapshot cursors; reject unknown arguments/fields/versions.
- JSON does not grant consent. Destructive operations without a TTY return `confirmation_required`.
- No initial unattended execution, `--yes`, `--force`, wildcard deletion, or reusable deletion token.

## 3. Commands and side effects

R reads business state. W writes local configuration/drafts/snapshots/plans without changing cleanup targets. D moves, restores, or permanently removes target data.

| Command | Level | Purpose |
| --- | --- | --- |
| `capabilities` | R | Actual support, contract version, limitations, inputs |
| `locations list` | R | Explicit built-in roots, availability, rule IDs and inspection issues |
| `startup list` | R | Bounded macOS launchd-definition inventory; optional `--include-system true\|false`, default false; settings guidance and unknown runtime/configured state |
| `system scan` | W | Cleanup-scope scan of available built-in roots; optionally include registered projects |
| `workspaces list / show` | R | Bindings and current-entry-point access |
| `workspaces add` | W | Register explicit path/root reference; not OS authorization |
| `workspaces remove` | W | Unregister root, bindings, and presets; preserve target files and receipts |
| `workspaces exclude add / remove` | W | Workspace exclusions; optional `--project` scopes the pattern to an exact relative project directory |
| `exclusions list` | R | Global and optional workspace patterns, plus the effective combination |
| `exclusions global add / remove` | W | Protection for all current and future workspaces; invalidate old scans/plans |
| `rules schema` | R | Bundled schema, no network retrieval |
| `rules validate` | R | Structure/static semantics and unverified bindings |
| `rules import` | W | Versioned disabled draft |
| `rules list / show / export` | R | Query/share without access credentials |
| `rules enable / disable` | W | Explicit binding state, no cleanup |
| `rules preview` | W | Read-only draft scan, saved as preview-only |
| `scan` | W | Exactly one of `--workspace` or `--location`; `--scope full\|cleanup`, default `full` |
| `scan results` | R | Stable paginated evidence |
| `plan create` | W | Concrete explicitly selected candidates |
| `plan show` | R | Paths, action, risk, digest, expiry, next actions |
| `plan execute` | D | Current-plan interactive confirmation |
| `history list / show` | R | Batch and item outcomes |
| `history inspect` | R | Bounded inspection of exact recorded original/Trash paths; no record changes or operation retries |
| `history restore` | D | Separately confirm verified receipt items |
| `history purge` | D | Separately confirm irreversible removal of this batch’s items |
| `presets list / save / show / scan` | R/W | Reuse logic; scan creates fresh evidence, not permission |

Discover actual availability rather than assuming every documented command exists.

`startup list --json` does not open cleanup storage. Its `scope` is `launchd_definitions`; completeness applies to the requested sources, while `unavailable_sources` identifies Login Items, background registrations and embedded helpers outside that scope. Source failures retain a partial envelope and exit `6`. Arguments/environment values are omitted; configured/runtime states remain `unknown`. It cannot change startup settings. See [startup discovery](../product/startup-items.md).

## 4. Example workflow

Paths/IDs below are fictional. Use actual returned IDs at each step.

Common application discovery requires no directory selection:

```sh
shou locations list --json
shou system scan --max-entries 100000 --max-seconds 60 --json
shou scan --location "chrome" --scope cleanup --json
shou system scan --include-projects true --json
```

`locations list` does not register roots. `system scan` registers existing explicit roots before scanning, preserves existing exclusions and disabled bindings, and returns `locations`, `scans`, `issues` and `skipped_location_ids`. It uses cleanup scope. `--include-projects true|false` defaults to `false`; `true` also scans already registered project workspaces. The desktop standard scan uses `true`. Neither entry implicitly scans home to discover projects. Each scan has its own workspace and evidence. Missing roots are skipped; inaccessible and incomplete roots produce a partial envelope and exit `6`. Cancellation stops the operation. There is no combined home-root plan or implicit cleanup. Known running applications are blocked in results and rechecked before mutation; `application_running` and `application_activity_unavailable` identify those decisions.

`scan --scope full|cleanup` defaults to `full` for compatibility. Full mode measures the workspace tree; cleanup mode follows enabled-rule prefixes, prunes `.git` during discovery and fully measures matched targets. A cleanup result can have completed discovery while remaining sparse. It is unsuitable for complete directory-space accounting.

```sh
shou capabilities --json
shou rules schema --json
shou workspaces add --path "/Users/alice/Developer" --root-ref "developer-workspaces" --json
shou rules validate --file "examples/rules/rust-target.rule.json" --json
shou rules import --file "examples/rules/rust-target.rule.json" --json
shou rules preview --file "examples/rules/rust-target.rule.json" --workspace "ws_example" --json
```

After review:

```sh
shou rules enable --rule-id "dev.rust-target" --workspace "ws_example" --json
shou scan --workspace "ws_example" --rule-id "dev.rust-target" --json
shou scan results --scan-id "scan_example" --limit 50 --json
shou plan create --scan-id "scan_example" --candidate "candidate_example" --json
shou plan show --plan-id "plan_example" --json
shou plan execute --plan-id "plan_example"
shou history show --execution-id "execution_example" --json
```

Draft preview snapshots are not executable: enable, rescan, then select candidates. `plan create` has no implicit select-all; repeat `--candidate` for additional items.

### Exclusion management

```sh
shou exclusions list --workspace "ws_example" --json
shou exclusions global add --pattern "**/keep/**" --json
shou workspaces exclude add --workspace "ws_example" --project "apps/demo" --pattern "**" --json
shou workspaces exclude remove --workspace "ws_example" --project "apps/demo" --pattern "**" --json
shou exclusions global remove --pattern "**/keep/**" --json
```

Global patterns are relative to every registered root, including roots registered later. `--project` must be an exact workspace-relative directory without wildcards or parent traversal; the example persists `apps/demo/**`. The CLI requires `--pattern` in project scope. Global, workspace and per-rule exclusions accumulate; a workspace cannot override a global protection. Matching a descendant blocks the containing cleanup target with `excluded_descendant` rather than partially deleting that directory.

`exclusions list` returns `global_patterns`, `workspace_patterns` and their stable, deduplicated `effective_patterns`; `workspace_id` is present when requested. Per-rule exclusions stay in rule definitions and are not included in this configuration list. Changing protection only changes configuration, invalidates existing evidence and requires a fresh scan; it never starts cleanup. Adding the first nonempty global protection upgrades local configuration to version `2`. Earlier builds refuse this configuration, even after the last global pattern is removed; see the [data model](../architecture/data-model.md).

## 5. Result envelope

```json
{
  "api_version": "1.0",
  "request_id": "request_example",
  "ok": true,
  "status": "success",
  "data": {
    "plan_id": "plan_example",
    "digest": "sha256:example-not-a-real-digest",
    "state": "ready",
    "item_count": 1,
    "allocated_bytes_estimate": 2147483648,
    "action": "trash",
    "confirmation_required": true
  },
  "warnings": [],
  "error": null,
  "next_actions": [
    {"command": "plan show", "arguments": {"plan_id": "plan_example"}},
    {"command": "plan execute", "arguments": {"plan_id": "plan_example"}, "requires_interactive_confirmation": true}
  ]
}
```

`status`: `success`, `partial`, `error`, or `cancelled`; `ok=true` only for success. Structured next actions are neither Shell strings nor authorization.

Errors include `code`, `message`, `details`, and `retryable`. Field locations and machine codes remain stable; human messages may be localized.

## 6. Scan results

Include candidate/workspace IDs, relative/display paths, identity summary, size basis, completeness, matching rule versions, condition evidence, effective risk, and protection outcomes. Unclassified directories remain analysis-only.

Scan metadata identifies `scope` and `tree_complete`; snapshots retain independently complete subtree coverage. A partial scan can produce plan items only for fully covered, eligible candidates whose complete manifests reproduce under current policy. Missing legacy coverage never grants partial targets eligibility. `complete` in cleanup mode does not mean the entire workspace was measured. Immutable snapshots provide stable pagination; agents query by ID rather than rely on truncated tables.

## 7. Exit codes

| Exit | Category | Examples |
| --- | --- | --- |
| `0` | Success | No error |
| `2` | Input/contract | `invalid_argument`, `invalid_rule`, `unsupported_schema` |
| `3` | Access | `permission_denied`, `access_expired` |
| `4` | State/conflict | `plan_stale`, `already_executed`, `store_busy` |
| `5` | I/O/storage | `io_error`, `store_corrupt`, `journal_unavailable` |
| `6` | Incomplete/budget | `partial_result`, `resource_limit` |
| `7` | Confirmation absent | `confirmation_required` |
| `8` | Unavailable capability | `unsupported_platform`, `capability_unavailable` |
| `130` | Cancellation | `cancelled` |

Return the primary blocking category and preserve item details. Process-start failure may yield no JSON; callers must also inspect process outcomes.

## 8. Confirmation and interruption

Display plan ID/digest, inspectable full scope, count, action, and risk before active confirmation. JSON execution may prompt through a separate controlling terminal; no terminal means exit 7. Confirmation is current, one-time, and in-process.

TTY interaction does not prove a human identity. External agents remain subject to their own tool permissions. Never expand scope or retry deletion after revalidation fails.

Repeated execution returns `already_executed` and existing receipt references. After timeout/interruption, query state before any retry. Reimporting identical same-version content is idempotent; changed content conflicts. Recovery/purge accepts verified receipt/item IDs, not arbitrary Trash paths.

`history inspect --execution-id "execution_example" --json` acquires the shared mutation lease and returns current metadata/manifest observations without rewriting receipts. A live competing operation returns `store_busy`. Optional `--max-entries` and `--max-seconds` use the scan budget limits and bound aggregate manifest inspection. The report contains `recorded_state`, `unfinished`, `checked_at`, and per-item `original`, `trash` and latest `follow_up`. Object observations are `matches`, `missing`, `changed`, `unavailable` or `not_recorded`; item summaries include `verified_trash`, `verified_original`, `restore_conflict`, `restored`, `purged`, `missing` and `needs_verification`. Incomplete/ambiguous observations produce `status=partial` and exit `6`.

`matches` checks identity and the saved directory manifest, not cryptographic file contents. A completed inspection is not a completed cleanup or authorization. A pending follow-up stays blocked even when an object is observed at the original location. If a process exits inside the system Trash call before its returned path is recorded, Shou reports the missing destination as unknown; it does not enumerate Trash, guess names or replay the operation. Every started item now has a durable `moving` state before the filesystem call, so a lost result cannot be displayed as a skipped item.

The desktop displays actual execution stage, current path and processed/total items, with a visible stop-request state. Core stops starting new items at a safe boundary. A system Trash call already in progress may finish; its verified result is recorded before stopping. Progress is not a completion receipt or freed-space claim, and does not change the CLI's single-result JSON envelope.

## 9. Compatibility

Maintain separate application, rule-format, and CLI API versions. Additive optional data may remain compatible; required-field or semantic changes need a contract version. Capability discovery describes actual support, including runtime locales.

## Built-in discovery and space browsing

A registered workspace can be scanned immediately without importing personal rules. Built-in matches still pass protection, plan-digest, and execution-revalidation gates; enabling them never authorizes cleanup. The `shou.builtin.` namespace is reserved and cannot be overridden by imported personal rules.

| Command | Behavior |
| --- | --- |
| `rules catalog [--workspace <id>]` | Built-in templates, or scoped definitions for a registered workspace |
| `analysis summary --scan-id <id>` | Measured root, non-overlapping cleanup categories, completeness, metric |
| `analysis children --scan-id <id> [--path <relative>] [--limit <n>] [--cursor <cursor>]` | Direct children ordered by allocated space, with stable pagination; root defaults to `.` |

`rules list` also returns `builtin_templates`. Existing `rules disable / enable` commands control built-in rules. Enabled by default means available for scan matching only. Directory cursors are bound to both the snapshot and exact directory. Analysis includes files and directories without cleanup rules; browsing never grants deletion authority.

`analysis summary` and `analysis children` require a full-scope snapshot. They reject cleanup-scope snapshots with `partial_result`; run `scan --scope full` first. A partial full scan still reports its gaps rather than treating missing data as zero.

```sh
shou rules catalog --workspace "ws_example" --json
shou scan --workspace "ws_example" --scope full --json
shou analysis summary --scan-id "scan_example" --json
shou analysis children --scan-id "scan_example" --path "." --limit 50 --json
```


## Application discovery and uninstall

`applications list [--include-system true|false] --json` is a bounded read that does not open the cleanup store. `applications inspect --path <exact-app-path>` saves a component review; optional scan budgets use the existing limits. `applications plan --review-id <id> --component <id>... [--include-user-data true|false]` requires explicit eligible components including the application. Personal-data consent defaults false. `applications plan show --plan-id <id>` exposes the reviewed scope.

`applications uninstall --plan-id <id>` is destructive and requires a controlling terminal plus the exact `UNINSTALL <plan-id>` phrase. There is no unattended confirmation option. The result is an ordinary history receipt with `operation=application_uninstall` and per-item original-parent evidence. `history inspect` and separately confirmed `history restore` work across all component parents; uninstall receipts reject `history purge`. JSON component `eligible`, `requires_user_data_consent`, `reasons` and `warnings` are explicit, and warnings do not authorize execution. See [application uninstall](../product/application-uninstall.md).
