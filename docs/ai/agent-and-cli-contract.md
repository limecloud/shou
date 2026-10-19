# CLI and structured operation contract

English | [简体中文](../zh-CN/ai/agent-and-cli-contract.md)

Status: API `1.0` design draft. Commands are not implemented and cannot currently be run.

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
| `workspaces list / show` | R | Bindings and current-entry-point access |
| `workspaces add` | W | Register explicit path/root reference; not OS authorization |
| `workspaces exclude add / remove` | W | Exclusions; invalidate old plans |
| `rules schema` | R | Bundled schema, no network retrieval |
| `rules validate` | R | Structure/static semantics and unverified bindings |
| `rules import` | W | Versioned disabled draft |
| `rules list / show / export` | R | Query/share without access credentials |
| `rules enable / disable` | W | Explicit binding state, no cleanup |
| `rules preview` | W | Read-only draft scan, saved as preview-only |
| `scan` | W | Enabled-rule scan and completeness |
| `scan results` | R | Stable paginated evidence |
| `plan create` | W | Concrete explicitly selected candidates |
| `plan show` | R | Paths, action, risk, digest, expiry, next actions |
| `plan execute` | D | Current-plan interactive confirmation |
| `history list / show` | R | Batch and item outcomes |
| `history restore` | D | Separately confirm verified receipt items |
| `history purge` | D | Separately confirm irreversible removal of this batch’s items |
| `presets list / save / show / scan` | R/W | Reuse logic; scan creates fresh evidence, not permission |

Discover actual availability rather than assuming every documented command exists.

## 4. Example workflow

Paths/IDs below are fictional. Use actual returned IDs at each step.

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

Partial scans cannot produce executable plans. Immutable snapshots provide stable pagination; agents query by ID rather than rely on truncated tables.

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

## 9. Compatibility

Maintain separate application, rule-format, and CLI API versions. Additive optional data may remain compatible; required-field or semantic changes need a contract version. Capability discovery describes actual support, including runtime locales.
